import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import 'package:calltype_core/storage/database.dart';
import 'package:calltype_core/network/api_client.dart';

import '../chat/chat_controller.dart' show controlTypes;
import 'contact_sync.dart' show contactRemovedPrefix;

/// Manages the local contact list — devices we have exchanged identity
/// keys with or intend to communicate with.
///
/// Contacts are stored locally and never synced to the server, preserving
/// the anonymous-first design. A contact is created when:
///   1. The user scans a QR code (gets handle + deviceId)
///   2. The user manually enters a handle
///   3. I send a message in a 1:1 chat whose peer is not a contact yet
///      ([addPeerOnReply]), or pick Add / Rename in that chat's menu
///      ([ensureContact]). A message that only ARRIVES adds nothing, so
///      spam senders do not become contacts
///      (spec 2026-11-09-contacts-from-replies).
///
/// The identity key exchange happens lazily on first message send —
/// the sender fetches the recipient's key bundle from the server and
/// performs X3DH. This means a contact can exist in the DB before any
/// cryptographic session is established.
class ContactsController extends ChangeNotifier {
  ContactsController({
    required AppDatabase database,
    ApiClient? apiClient,
    Future<void> Function(String deviceId)? onLocalChange,
    Future<void> Function(String deviceId, int removedAt)? onLocalRemove,
    Stream<void>? remoteChanges,
  }) : _db = database,
       _api = apiClient,
       _onLocalChange = onLocalChange,
       _onLocalRemove = onLocalRemove {
    _remote = remoteChanges?.listen((_) => unawaited(loadContacts()));
  }
  final ApiClient? _api;

  /// Contact sync (spec 2026-11-08-contact-sync): told the device id of
  /// every local add or rename, so our other devices get it.
  final Future<void> Function(String deviceId)? _onLocalChange;

  /// Contact sync of a local removal (spec 2026-11-09-delete-chats-contacts
  /// D4): told the device id and the removal time, so our other devices
  /// remove the contact too.
  final Future<void> Function(String deviceId, int removedAt)? _onLocalRemove;

  /// Contacts changed by another own device: reload.
  StreamSubscription<void>? _remote;

  final AppDatabase _db;

  /// All known contacts, ordered by display name / handle.
  List<Contact> get contacts => List.unmodifiable(_contacts);
  List<Contact> _contacts = [];

  /// Loads all contacts from the local database.
  ///
  /// Orders by displayName (if set), falling back to userHandle for
  /// contacts that haven't been given a custom name yet.
  Future<void> loadContacts() async {
    final query = _db.select(_db.contacts)
      ..orderBy([
        // COALESCE equivalent — sort by displayName if present, else handle.
        (c) => OrderingTerm(expression: c.displayName),
        (c) => OrderingTerm(expression: c.userHandle),
      ]);

    _contacts = await query.get();
    notifyListeners();
  }

  /// Sets the local nickname of a contact; blank/null clears it so the
  /// handle is shown again.
  ///
  /// Never sent to the server, so the other person's own profile name (and
  /// what bots match on) is unaffected; it reaches only our own other
  /// devices, end-to-end encrypted (contact sync).
  Future<void> renameContact(String deviceId, String? name) async {
    final trimmed = name?.trim();
    await (_db.update(_db.contacts)..where((c) => c.deviceId.equals(deviceId)))
        .write(
          ContactsCompanion(
            displayName: Value(
              trimmed == null || trimmed.isEmpty ? null : trimmed,
            ),
            nameChangedAt: Value(DateTime.now().millisecondsSinceEpoch),
          ),
        );
    await loadContacts();
    _changed(deviceId);
  }

  /// Removes the contact [deviceId] on this identity (spec D4). Writes the
  /// same `contact-removed:` tombstone a synced removal writes, so a late,
  /// older upsert cannot bring it back, and tells our other devices. The
  /// person is not blocked: a new message from them still arrives (and a
  /// reply makes them a contact again, spec contacts-from-replies).
  Future<void> deleteContact(String deviceId) async {
    final removedAt = DateTime.now().millisecondsSinceEpoch;
    await _db.transaction(() async {
      await (_db.delete(
        _db.contacts,
      )..where((c) => c.deviceId.equals(deviceId))).go();
      await _db
          .into(_db.backupState)
          .insertOnConflictUpdate(
            BackupStateCompanion.insert(
              key: '$contactRemovedPrefix$deviceId',
              value: '$removedAt',
            ),
          );
    });
    await loadContacts();
    final notify = _onLocalRemove;
    if (notify != null) {
      // Best effort, like [_changed]: a failed sync stays queued.
      unawaited(notify(deviceId, removedAt).catchError((Object _) {}));
    }
  }

  void _changed(String deviceId) {
    final notify = _onLocalChange;
    if (notify == null) return;
    // Best effort and never blocking the UI: a failed sync stays queued in
    // the own-device outbox and is retried on reconnect.
    unawaited(notify(deviceId).catchError((Object _) {}));
  }

  /// Adds a contact by their human-readable handle (e.g. CT-A1B2-C3D4).
  ///
  /// The handle is stored immediately. The actual key exchange happens
  /// on first message send — at that point the app fetches the key bundle
  /// from the server via the deviceId and performs X3DH.
  ///
  /// A placeholder identity key (empty bytes) is stored because the
  /// Contacts table requires a non-null identityKey. It will be populated
  /// when the key bundle is fetched during session initialization.
  ///
  /// [handle] must match the CT-XXXX-XXXX format.
  /// [deviceId] is optional — if provided (e.g. from QR scan), it's used
  /// as the primary key. If not, the handle itself is used as a temporary
  /// deviceId until the server resolves it.
  Future<void> addContactByHandle(String handle, {String? deviceId}) async =>
      addContact(await resolveContact(handle, deviceId: deviceId));

  /// Resolves a handle / invite to a device WITHOUT saving it, so the UI can
  /// show who (and in particular: whether a bot) is about to be added before
  /// the user confirms.
  Future<ContactPreview> resolveContact(
    String handle, {
    String? deviceId,
  }) async {
    final invite = Uri.tryParse(handle);
    if (invite?.scheme == 'ct' && invite!.pathSegments.isNotEmpty) {
      deviceId = invite.host;
      handle = invite.pathSegments.first;
    }
    var isBot = false;
    // The remote device's own chosen display name, if any — used only as a
    // one-time suggestion when the contact is first saved (see addContact).
    String? displayName;
    final api = _api;
    if (deviceId == null) {
      if (api == null) {
        throw StateError(
          'Contact lookup is unavailable. Paste a complete invite.',
        );
      }
      final result = await api.findDeviceByHandle(handle.trim().toUpperCase());
      deviceId = result['deviceId'] as String;
      handle = result['userHandle'] as String;
      isBot = result['isBot'] == true;
      displayName = result['displayName'] as String?;
    } else if (api != null) {
      // A complete invite needs no lookup to be added, but it does not say
      // whether the device is a bot. Ask the handle lookup (NOT the key
      // bundle — fetching a bundle burns one of the peer's one-time
      // pre-keys). Best effort: invites must keep working offline.
      try {
        final result = await api.findDeviceByHandle(handle);
        if (result['deviceId'] == deviceId) {
          isBot = result['isBot'] == true;
          displayName = result['displayName'] as String?;
        }
      } catch (_) {}
    }
    if (!RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(deviceId)) {
      throw const FormatException('Invalid contact invite.');
    }
    return ContactPreview(
      deviceId: deviceId,
      handle: handle,
      isBot: isBot,
      displayName: displayName,
    );
  }

  /// Persists a contact previously returned by [resolveContact].
  Future<void> addContact(ContactPreview preview) async {
    final id = preview.deviceId;

    // Check if this contact already exists to avoid duplicates.
    final existing = await (_db.select(
      _db.contacts,
    )..where((c) => c.deviceId.equals(id))).getSingleOrNull();

    if (existing != null) return;

    final companion = ContactsCompanion.insert(
      deviceId: id,
      userHandle: preview.handle,
      // Placeholder — real identity key is populated during X3DH handshake
      // when the first message is sent to this contact.
      identityKey: Uint8List(0),
      addedAt: DateTime.now(),
      isBot: Value(preview.isBot),
      // One-time suggestion from the remote device's own profile. After this
      // it is purely local — renaming a contact never touches their server
      // profile, and a later profile change on their end won't overwrite it.
      displayName: Value(preview.displayName),
    );

    await _db.into(_db.contacts).insert(companion);
    await loadContacts();
    _changed(id);
  }

  // -- Contacts from replies (spec 2026-11-09-contacts-from-replies) -------

  /// Key prefix of the cached peer profiles in `backup_state` (C4). A cache
  /// only: not part of backups, refetched after [peerProfileMaxAge].
  static const peerProfileKeyPrefix = 'peer-profile:';

  /// How long a cached peer profile is used before it is fetched again.
  static const peerProfileMaxAge = Duration(hours: 24);

  /// After a failed lookup (offline, old server) the next try waits this
  /// long, so a rebuilding chat list does not hammer the server.
  static const _peerProfileRetryAfter = Duration(minutes: 5);

  static final _deviceIdPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  final _profiles = <String, PeerProfile>{};
  final _profileLoads = <String>{};
  final _profileFailedAt = <String, DateTime>{};
  final _adds = <String, Future<Contact>>{};
  bool _disposed = false;

  /// The saved contact for [deviceId], if any.
  Contact? contactOf(String deviceId) =>
      _contacts.where((c) => c.deviceId == deviceId).firstOrNull;

  /// The public profile of a 1:1 peer that may not be a contact (C4), for a
  /// readable chat title instead of the raw device id. Returns what is
  /// cached (possibly null) and, when nothing fresh is cached, starts a
  /// background lookup that notifies listeners once it lands. Safe to call
  /// from build methods.
  PeerProfile? peerProfile(String deviceId) {
    final cached = _profiles[deviceId];
    if (cached == null ||
        DateTime.now().difference(cached.fetchedAt) > peerProfileMaxAge) {
      unawaited(_loadPeerProfile(deviceId));
    }
    return cached;
  }

  Future<void> _loadPeerProfile(String deviceId) async {
    // Without an API there is nothing to look up (tests, bots); a non-GUID id
    // is never a device and would only produce a 404.
    if (_api == null || !_deviceIdPattern.hasMatch(deviceId)) return;
    final failedAt = _profileFailedAt[deviceId];
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < _peerProfileRetryAfter) {
      return;
    }
    if (!_profileLoads.add(deviceId)) return;
    try {
      if (!_profiles.containsKey(deviceId)) {
        final row =
            await (_db.select(_db.backupState)..where(
                  (s) => s.key.equals('$peerProfileKeyPrefix$deviceId'),
                ))
                .getSingleOrNull();
        final stored = row == null ? null : PeerProfile.tryParse(row.value);
        if (stored != null) {
          _profiles[deviceId] = stored;
          _notify();
          if (DateTime.now().difference(stored.fetchedAt) <=
              peerProfileMaxAge) {
            return;
          }
        }
      }
      await _fetchPeerProfile(deviceId);
      _notify();
    } catch (_) {
      // C5: a failed lookup only means the title stays as it was.
      _profileFailedAt[deviceId] = DateTime.now();
    } finally {
      _profileLoads.remove(deviceId);
    }
  }

  /// Asks the server for [deviceId]'s profile (C1) and caches it. Throws
  /// when offline, on an old server (404) or on a mismatching answer.
  Future<PeerProfile> _fetchPeerProfile(String deviceId) async {
    final api = _api;
    if (api == null) {
      throw StateError('Contact lookup is unavailable.');
    }
    final result = await api.getDeviceProfile(deviceId);
    final handle = result['userHandle'];
    if (result['deviceId'] is! String ||
        (result['deviceId'] as String).toLowerCase() !=
            deviceId.toLowerCase() ||
        handle is! String ||
        handle.isEmpty) {
      throw const FormatException('Unexpected device profile.');
    }
    final profile = PeerProfile(
      handle: handle,
      displayName: result['displayName'] as String?,
      isBot: result['isBot'] == true,
      fetchedAt: DateTime.now(),
    );
    _profiles[deviceId] = profile;
    _profileFailedAt.remove(deviceId);
    await _db
        .into(_db.backupState)
        .insertOnConflictUpdate(
          BackupStateCompanion.insert(
            key: '$peerProfileKeyPrefix$deviceId',
            value: profile.encode(),
          ),
        );
    return profile;
  }

  /// Returns the contact for [deviceId], adding it first when it is not one
  /// yet (C2/C3): handle, bot flag and display-name suggestion come from a
  /// fresh profile lookup (C1). The add goes through [addContact], so contact
  /// sync carries it to our other devices. Concurrent calls for the same id
  /// share one lookup and add. Throws when the lookup fails (C5).
  Future<Contact> ensureContact(String deviceId) {
    final running = _adds[deviceId];
    if (running != null) return running;
    final add = () async {
      final existing = await _contactRow(deviceId);
      if (existing != null) return existing;
      final profile = await _fetchPeerProfile(deviceId);
      await addContact(
        ContactPreview(
          deviceId: deviceId,
          handle: profile.handle,
          isBot: profile.isBot,
          displayName: profile.displayName,
        ),
      );
      return (await _contactRow(deviceId))!;
    }();
    _adds[deviceId] = add;
    return add.whenComplete(() => _adds.remove(deviceId));
  }

  Future<Contact?> _contactRow(String deviceId) => (_db.select(
    _db.contacts,
  )..where((c) => c.deviceId.equals(deviceId))).getSingleOrNull();

  /// The chat send path's hook (C2), called with the id of every message
  /// this device queues or retries. When it is my own non-control message
  /// in a direct conversation whose peer is not a contact yet, the peer is
  /// added. Group and business conversations are left alone (C6). Never
  /// throws and never blocks the send: a failed lookup is simply tried again
  /// on the next send (C5).
  Future<void> addPeerOnReply(String messageId) async {
    try {
      final message = await (_db.select(
        _db.messages,
      )..where((m) => m.id.equals(messageId))).getSingleOrNull();
      if (message == null || controlTypes.contains(message.type)) return;
      final conversation =
          await (_db.select(_db.conversations)
                ..where((c) => c.id.equals(message.conversationId)))
              .getSingleOrNull();
      if (conversation == null ||
          conversation.type != 'direct' ||
          conversation.organizationId != null ||
          // In a direct chat the conversation id is the peer; a row sent BY
          // the peer is an incoming message, never a reply of mine.
          message.senderId == conversation.id ||
          !_deviceIdPattern.hasMatch(conversation.id)) {
        return;
      }
      await ensureContact(conversation.id);
    } catch (_) {}
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _remote?.cancel();
    super.dispose();
  }
}

/// A 1:1 peer's public profile from `GET /devices/{id}/profile`, cached so a
/// chat with a non-contact gets a readable title (C4).
class PeerProfile {
  const PeerProfile({
    required this.handle,
    required this.isBot,
    required this.fetchedAt,
    this.displayName,
  });

  final String handle;
  final String? displayName;
  final bool isBot;
  final DateTime fetchedAt;

  /// What a chat title shows: the peer's own display name, else the handle.
  String get label {
    final name = displayName?.trim();
    return name == null || name.isEmpty ? handle : name;
  }

  String encode() => jsonEncode({
    'userHandle': handle,
    'displayName': displayName,
    'isBot': isBot,
    'fetchedAt': fetchedAt.millisecondsSinceEpoch,
  });

  /// Null for a malformed cache row (it is then fetched again).
  static PeerProfile? tryParse(String value) {
    try {
      final json = jsonDecode(value);
      if (json is! Map<String, dynamic>) return null;
      final handle = json['userHandle'];
      final fetchedAt = json['fetchedAt'];
      if (handle is! String || fetchedAt is! int) return null;
      final name = json['displayName'];
      return PeerProfile(
        handle: handle,
        displayName: name is String ? name : null,
        isBot: json['isBot'] == true,
        fetchedAt: DateTime.fromMillisecondsSinceEpoch(fetchedAt),
      );
    } catch (_) {
      return null;
    }
  }
}

/// A resolved but not yet saved contact, shown in the add-contact preview.
class ContactPreview {
  const ContactPreview({
    required this.deviceId,
    required this.handle,
    required this.isBot,
    this.displayName,
  });

  final String deviceId;
  final String handle;

  /// Self-declared by the device; see `Contacts.isBot` in the schema.
  final bool isBot;

  /// The remote device's own chosen display name at resolve time, if any.
  final String? displayName;
}
