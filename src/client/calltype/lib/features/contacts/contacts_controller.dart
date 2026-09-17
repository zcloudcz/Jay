import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../../core/storage/database.dart';
import '../../core/network/api_client.dart';

/// Manages the local contact list — devices we have exchanged identity
/// keys with or intend to communicate with.
///
/// Contacts are stored locally and never synced to the server, preserving
/// the anonymous-first design. A contact is created when:
///   1. The user scans a QR code (gets handle + deviceId)
///   2. The user manually enters a handle
///   3. A message arrives from an unknown sender (auto-create)
///
/// The identity key exchange happens lazily on first message send —
/// the sender fetches the recipient's key bundle from the server and
/// performs X3DH. This means a contact can exist in the DB before any
/// cryptographic session is established.
class ContactsController extends ChangeNotifier {
  ContactsController({required AppDatabase database, ApiClient? apiClient})
    : _db = database,
      _api = apiClient;
  final ApiClient? _api;

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
    } else if (api != null) {
      // A complete invite needs no lookup to be added, but it does not say
      // whether the device is a bot. Ask the handle lookup (NOT the key
      // bundle — fetching a bundle burns one of the peer's one-time
      // pre-keys). Best effort: invites must keep working offline.
      try {
        final result = await api.findDeviceByHandle(handle);
        isBot = result['deviceId'] == deviceId && result['isBot'] == true;
      } catch (_) {}
    }
    if (!RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(deviceId)) {
      throw const FormatException('Invalid contact invite.');
    }
    return ContactPreview(deviceId: deviceId, handle: handle, isBot: isBot);
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
    );

    await _db.into(_db.contacts).insert(companion);
    await loadContacts();
  }
}

/// A resolved but not yet saved contact, shown in the add-contact preview.
class ContactPreview {
  const ContactPreview({
    required this.deviceId,
    required this.handle,
    required this.isBot,
  });

  final String deviceId;
  final String handle;

  /// Self-declared by the device; see `Contacts.isBot` in the schema.
  final bool isBot;
}
