import 'dart:async';
import 'dart:convert';

import 'package:calltype_core/crypto/device_list.dart';
import 'package:calltype_core/devices/device_directory.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:calltype_core/crypto/key_manager.dart';
import 'package:calltype_core/crypto/session_manager.dart';
import 'package:calltype_core/network/api_client.dart';
import '../../core/network/signalr_client.dart';
import 'package:calltype_core/storage/database.dart';
import '../chat/message_inbox_service.dart' show MessageProcessingQueue;

/// What a companion knows about its own link (shown on the chat list).
enum CompanionStatus {
  /// Not a companion, or a companion whose list verified.
  ok,

  /// The list this companion is in is missing or does not verify. Nothing is
  /// deleted: otherwise the server could force a wipe by lying (spec Part A,
  /// "Removing a device").
  cannotVerify,

  /// A verified, newer list no longer contains this device; its chats were
  /// deleted.
  removed,
}

/// BackupState key: the handle of the primary this device is linked to.
/// The hub's LinkOffer carries it; it is shown on the companion and used for
/// its "My identity" invite.
const linkedPrimaryHandleKey = 'linked_primary_handle';

/// BackupState key: the primary this device is a companion of. Written when a
/// verified list adds us, deleted inside the wipe transaction. It survives a
/// crash between "the removal was stored" and "the wipe ran": [open] finishes
/// the wipe when the marker is still there but the stored list no longer
/// contains us. Without it nothing would ever re-trigger the wipe, because
/// the removal is already stored and a refresh reports no change.
const companionOfKey = 'companion_of';

/// BackupState key: JSON list of our companions the server claims no longer
/// exist, waiting for the user's decision (see [DeviceService.reportVanishedCompanions]).
const vanishedCompanionsKey = 'vanished_companions';

/// A change of this identity's own device list that contact sync acts on
/// (spec 2026-11-08-contact-sync).
enum OwnLinkEvent {
  /// This primary's verified list gained at least one companion.
  companionsAdded,

  /// This device just became a companion.
  becameCompanion,
}

/// [DeviceService.resetForLinking] refused: this device is a companion, or a
/// primary that has companions of its own.
class LinkResetRefused implements Exception {
  const LinkResetRefused();
}

/// App-wide owner of this device's multi-device state (spec Part A).
///
/// Built before onboarding (the inbox needs a reference at startup) and
/// [open]ed once the device has an id. Every list refresh it starts runs in
/// [MessageProcessingQueue]: a refresh may create a session (ratchet state),
/// and the inbox and the outbox refresh through the same queue.
class DeviceService extends ChangeNotifier {
  DeviceService({
    required AppDatabase database,
    required ApiClient apiClient,
    required KeyManager keyManager,
    required SessionManager sessionManager,
    required SignalRClient signalRClient,
  }) : _db = database,
       _api = apiClient,
       _keys = keyManager,
       _sessions = sessionManager,
       _signalR = signalRClient;

  final AppDatabase _db;
  final ApiClient _api;
  final KeyManager _keys;
  final SessionManager _sessions;
  final SignalRClient _signalR;
  static const _uuid = Uuid();

  DeviceDirectory? _directory;
  StreamSubscription<DeviceListChange>? _changes;
  StreamSubscription<Map<String, dynamic>>? _hints;
  CompanionStatus _status = CompanionStatus.ok;
  String? _pendingPrimary;
  bool _disposed = false;
  Set<String> _vanished = {};
  final _ownLinks = StreamController<OwnLinkEvent>.broadcast();

  /// See [OwnLinkEvent].
  Stream<OwnLinkEvent> get ownLinkEvents => _ownLinks.stream;

  bool get isOpen => _directory != null;

  DeviceDirectory get directory =>
      _directory ?? (throw StateError('This device is not registered yet.'));

  bool get isCompanion => _directory?.isCompanion ?? false;

  CompanionStatus get status => _status;

  /// Loads the verified lists for [deviceId]. Routing reads
  /// `selfIdentityId`, so this must finish before the hub delivers the first
  /// message (constraint 8).
  Future<void> open(String deviceId) async {
    if (_directory != null) return;
    final directory = DeviceDirectory(
      database: _db,
      apiClient: _api,
      selfDeviceId: deviceId,
      selfSigningKey: () async =>
          (await _keys.getSignedIdentityBundle())['signingKey']!,
      selfIdentityKey: _keys.getPublicIdentityKey,
    );
    await directory.load();
    _directory = directory;
    await _finishInterruptedWipe(directory);
    final saved = await (_db.select(
      _db.backupState,
    )..where((s) => s.key.equals(vanishedCompanionsKey))).getSingleOrNull();
    if (saved != null) {
      _vanished = {
        for (final id in jsonDecode(saved.value) as List) id as String,
      };
    }
    _changes = directory.changes.listen(
      (change) => unawaited(_onChange(change).catchError((Object _) {})),
    );
    _hints = _signalR.onDeviceListChanged.listen((event) {
      final primary = (event['primaryDeviceId'] as String?)?.toLowerCase();
      // The event is only a hint to refetch and verify. Only our own
      // identity, or the primary we just consented to join, is worth a fetch:
      // anything else would let the server make us pin and store arbitrary
      // identities.
      if (primary == null ||
          (primary != directory.selfIdentityId && primary != _pendingPrimary)) {
        return;
      }
      unawaited(checkOwnList(primary));
    });
    _notify();
  }

  /// The new device consented to join [primaryDeviceId]; its next list hint
  /// is the one that makes this device a companion.
  void expectLink(String primaryDeviceId) =>
      _pendingPrimary = primaryDeviceId.toLowerCase();

  /// The user gave up waiting: hints from that primary are ignored again.
  void cancelExpectedLink() => _pendingPrimary = null;

  Future<String?> linkedPrimaryHandle() async =>
      (await (_db.select(_db.backupState)
                ..where((s) => s.key.equals(linkedPrimaryHandleKey)))
              .getSingleOrNull())
          ?.value;

  /// Re-reads and verifies the list this device belongs to: on a
  /// DeviceListChanged hint, on every hub connect (a hint sent while we were
  /// offline is lost) and after our own PUT (fan-out targets come from the
  /// STORED list, constraint 5).
  ///
  /// Without an argument it checks the primary we consented to join while we
  /// wait for the link: a hint missed while offline would otherwise lose it.
  Future<void> checkOwnList([String? primaryDeviceId]) =>
      MessageProcessingQueue.forDatabase(_db).run(() async {
        final directory = _directory;
        if (directory == null) return;
        primaryDeviceId ??= _pendingPrimary;
        // Most devices never link anything: no own list and not a companion
        // means there is nothing to re-check, and a reconnect costs nothing.
        if (primaryDeviceId == null &&
            !directory.isCompanion &&
            await _ownList() == null) {
          return;
        }
        try {
          await directory.refresh(
            primaryDeviceId ?? directory.selfIdentityId,
            ensurePinned: _ensureSession,
          );
          // refresh() answers null both for "unchanged" and for "the server
          // has no list". Only the second matters for a companion, and only a
          // direct look tells them apart.
          if (directory.isCompanion &&
              await _api.getDeviceList(directory.selfDeviceId) == null) {
            _setStatus(CompanionStatus.cannotVerify);
            return;
          }
        } on DeviceListException {
          if (directory.isCompanion) _setStatus(CompanionStatus.cannotVerify);
          return;
        } catch (_) {
          // Offline, 429 or 5xx: no verdict about the list either way.
          return;
        }
        if (_status == CompanionStatus.cannotVerify) {
          _setStatus(CompanionStatus.ok);
        }
      });

  Future<void> _onChange(DeviceListChange change) async {
    final directory = _directory!;
    if (change.removed.contains(directory.selfDeviceId)) {
      await _wipe();
      return;
    }
    if (change.added.contains(directory.selfDeviceId)) {
      _pendingPrimary = null;
      await _setCompanionMarker(change.identityId);
      _setStatus(CompanionStatus.ok);
      _emit(OwnLinkEvent.becameCompanion);
      return;
    }
    // Our own identity (as primary or as companion): screens re-read, but no
    // line; the user linked that device themselves.
    if (change.identityId == directory.selfIdentityId) {
      await _pruneVanished();
      _notify();
      if (!directory.isCompanion && change.added.isNotEmpty) {
        _emit(OwnLinkEvent.companionsAdded);
      }
      return;
    }
    // A FIRST list counts too: the first new reader of an existing
    // conversation is exactly what must never be silent.
    await _noteDeviceChange(change);
  }

  /// Spec Part A, "What a peer sees": nothing happens silently, same
  /// principle as the visible auditor. One line per direction, not per
  /// device: the fact matters, not the count.
  Future<void> _noteDeviceChange(DeviceListChange change) async {
    final conversation = await (_db.select(
      _db.conversations,
    )..where((c) => c.id.equals(change.identityId))).getSingleOrNull();
    // ponytail: direct conversations only. A group would need the line in
    // every group shared with that person; add it when users ask for it.
    if (conversation == null || conversation.type != 'direct') return;
    final now = DateTime.now();
    for (final (kind, devices) in [
      ('added', change.added),
      ('removed', change.removed),
    ]) {
      if (devices.isEmpty) continue;
      await _db
          .into(_db.messages)
          .insert(
            MessagesCompanion.insert(
              id: _uuid.v4(),
              conversationId: change.identityId,
              senderId: change.identityId,
              body: Value(kind),
              type: const Value('device-change'),
              status: const Value('delivered'),
              createdAt: now,
              receivedAt: Value(now),
            ),
          );
    }
  }

  Future<void> _setCompanionMarker(String primaryId) => _db
      .into(_db.backupState)
      .insertOnConflictUpdate(
        BackupStateCompanion.insert(key: companionOfKey, value: primaryId),
      );

  /// Startup half of the wipe's crash safety (see [companionOfKey]).
  Future<void> _finishInterruptedWipe(DeviceDirectory directory) async {
    final marker = await (_db.select(
      _db.backupState,
    )..where((s) => s.key.equals(companionOfKey))).getSingleOrNull();
    if (directory.isCompanion) {
      // Linked (also covers a link stored before the marker existed).
      if (marker == null) await _setCompanionMarker(directory.selfIdentityId);
      return;
    }
    if (marker == null) return;
    final stored = await (_db.select(
      _db.knownDeviceLists,
    )..where((l) => l.primaryDeviceId.equals(marker.value))).getSingleOrNull();
    // No stored list means we cannot tell "removed" from "never verified";
    // only a verified list that lacks us proves the removal.
    if (stored == null) return;
    final listed = parseDeviceListPayload(stored.payload).devices;
    if (listed.any((d) => d.deviceId == directory.selfDeviceId)) return;
    await _wipe();
  }

  /// A verified, newer list without this device: delete what it holds of the
  /// identity's conversations. Keys and registration stay, so the device is
  /// simply an empty, standalone device again.
  ///
  /// The stored device lists are KEPT on purpose: the list that removed us is
  /// the rollback floor (minVersion). Deleting it would let a hostile server
  /// replay the old list that still contains us, re-link us and then "remove"
  /// us again, wiping data the user created after the first wipe.
  Future<void> _wipe() => MessageProcessingQueue.forDatabase(_db).run(() async {
    await _db.transaction(() async {
      await _db.delete(_db.messages).go();
      await _db.delete(_db.messageReactions).go();
      await _db.delete(_db.messagePins).go();
      await _db.delete(_db.pollVotes).go();
      await _db.delete(_db.conversations).go();
      await _db.delete(_db.contacts).go();
      await (_db.delete(_db.backupState)..where(
            (s) =>
                s.key.like('outbox:%') |
                s.key.like('ownsync:%') |
                s.key.like('control:%') |
                s.key.equals(companionOfKey) |
                s.key.equals(linkedPrimaryHandleKey),
          ))
          .go();
    });
    await _directory!.load();
    _setStatus(CompanionStatus.removed);
  });

  /// "Disconnect this device and link it with your phone" (link UX, A3): the
  /// user chose to give up what this device holds so it can become a
  /// companion, which only an EMPTY device may (decision 3). Same deletion as
  /// [_wipe], plus the Signal sessions: the identity of this device is given
  /// up, so ratchets with its old contacts must not keep decrypting their
  /// messages here once it reads the phone's conversations. Keys and
  /// registration stay (the device id is what the QR code carries), and so do
  /// the stored device lists, for the rollback reason given at [_wipe].
  ///
  /// Throws [LinkResetRefused] for a primary with companions: its list would
  /// be orphaned and the companions could no longer be managed.
  Future<void> resetForLinking() async {
    final directory = this.directory;
    if (directory.isCompanion || (await companions()).isNotEmpty) {
      throw const LinkResetRefused();
    }
    await MessageProcessingQueue.forDatabase(_db).run(() async {
      await _db.transaction(() async {
        await _db.delete(_db.messages).go();
        await _db.delete(_db.messageReactions).go();
        await _db.delete(_db.messagePins).go();
        await _db.delete(_db.pollVotes).go();
        await _db.delete(_db.conversations).go();
        await _db.delete(_db.contacts).go();
        await _db.delete(_db.signalSessions).go();
        await (_db.delete(_db.backupState)..where(
              (s) =>
                  s.key.like('outbox:%') |
                  s.key.like('ownsync:%') |
                  s.key.like('control:%') |
                  s.key.equals(companionOfKey) |
                  s.key.equals(linkedPrimaryHandleKey) |
                  s.key.equals(vanishedCompanionsKey),
            ))
            .go();
      });
      await directory.load();
    });
    _pendingPrimary = null;
    _vanished = {};
    _setStatus(CompanionStatus.ok);
  }

  Future<KnownDeviceList?> _ownList() =>
      (_db.select(_db.knownDeviceLists)
            ..where((l) => l.primaryDeviceId.equals(directory.selfDeviceId)))
          .getSingleOrNull();

  /// The companions in this primary's own verified list.
  Future<List<DeviceListEntry>> companions() async {
    final own = await _ownList();
    return own == null ? const [] : parseDeviceListPayload(own.payload).devices;
  }

  Future<void> addCompanion(DeviceListEntry entry) async {
    // Our own refresh rejects a list with an entry whose consent does not
    // verify, so signing one would freeze the list at the old version (the
    // server accepts it, we never store it, every later edit gets a 409).
    final consented = await verifyDeviceLinkConsent(
      consentSig: entry.consentSig,
      companionSigningKey: entry.signingKey,
      primaryDeviceId: directory.selfDeviceId,
      companionDeviceId: entry.deviceId,
    );
    if (!consented) throw const DeviceListException('missing_consent');
    await _publish(
      (current) => [
        for (final d in current)
          if (d.deviceId != entry.deviceId) d,
        entry,
      ],
    );
  }

  Future<void> removeCompanions(Set<String> deviceIds) => _publish(
    (current) => [
      for (final d in current)
        if (!deviceIds.contains(d.deviceId)) d,
    ],
  );

  /// Companions the server claims no longer exist and the user has not decided
  /// about yet.
  Set<String> get vanishedCompanions => Set.unmodifiable(_vanished);

  /// Constraint 5: a stale answer that leaves out one of OUR companions may
  /// mean the device deleted itself. It may also be a lying server, and
  /// re-signing without the device would then wipe a healthy companion (a
  /// verified removal is what triggers its wipe). So this only RECORDS the ids
  /// and the user decides ([confirmRemoveVanished] / [dismissVanished]).
  ///
  /// Only ids in our current verified list count: anything else is not ours to
  /// ask about. No network and no [MessageProcessingQueue] job, so callers
  /// already running inside that queue (the outbox repair) may call it
  /// fire-and-forget, or even await it, without waiting for themselves.
  Future<void> reportVanishedCompanions(Iterable<String> deviceIds) async {
    final directory = _directory;
    if (directory == null || directory.isCompanion) return;
    final own = {for (final d in await companions()) d.deviceId};
    final next = {
      ..._vanished,
      ...deviceIds.map((i) => i.toLowerCase()).where(own.contains),
    };
    if (next.length == _vanished.length) return;
    await _storeVanished(next);
  }

  /// The user agreed: re-sign the list without the vanished devices.
  ///
  /// [ids] limits it to the rows the user confirmed (one prompt per device);
  /// the others stay pending. Without it every pending device is removed.
  Future<void> confirmRemoveVanished({Iterable<String>? ids}) async {
    final chosen = ids == null
        ? _vanished.toSet()
        : _vanished.intersection({for (final i in ids) i.toLowerCase()});
    if (chosen.isEmpty) return;
    await removeCompanions(chosen);
    await _storeVanished(_vanished.difference(chosen));
  }

  /// The user keeps them (they may know the device is fine). A later stale
  /// answer reports the device again, so a real vanishing is not lost.
  /// [ids] dismisses only those rows, like [confirmRemoveVanished].
  Future<void> dismissVanished({Iterable<String>? ids}) {
    if (ids == null) return _storeVanished({});
    final keep = _vanished.difference({for (final i in ids) i.toLowerCase()});
    return _storeVanished(keep);
  }

  /// Forgets reported ids that are no longer in our list (e.g. removed
  /// normally), so the prompt never asks about a device that is already gone.
  Future<void> _pruneVanished() async {
    if (_vanished.isEmpty) return;
    final own = {for (final d in await companions()) d.deviceId};
    final next = _vanished.where(own.contains).toSet();
    if (next.length != _vanished.length) await _storeVanished(next);
  }

  Future<void> _storeVanished(Set<String> ids) async {
    _vanished = ids;
    if (ids.isEmpty) {
      await (_db.delete(
        _db.backupState,
      )..where((s) => s.key.equals(vanishedCompanionsKey))).go();
    } else {
      await _db
          .into(_db.backupState)
          .insertOnConflictUpdate(
            BackupStateCompanion.insert(
              key: vanishedCompanionsKey,
              value: jsonEncode(ids.toList()),
            ),
          );
    }
    _notify();
  }

  /// Signs version + 1 of this primary's list with [edit] applied and
  /// uploads it (spec Part A, steps 5 and "Removing a device").
  Future<void> _publish(
    List<DeviceListEntry> Function(List<DeviceListEntry> current) edit,
  ) async {
    final directory = this.directory;
    if (directory.isCompanion) {
      throw StateError('Only the primary device signs its device list.');
    }
    for (var attempt = 1; ; attempt++) {
      final own = await _ownList();
      final signed = await signDeviceList(
        primarySigningKey: await _keys.getSigningKeyPair(),
        list: DeviceList(
          primaryDeviceId: directory.selfDeviceId,
          version: (own?.version ?? 0) + 1,
          devices: edit(
            own == null
                ? const []
                : parseDeviceListPayload(own.payload).devices,
          ),
        ),
      );
      try {
        await _api.putDeviceList(
          directory.selfDeviceId,
          payload: signed.payload,
          signature: signed.signature,
        );
        break;
      } on DioException catch (e) {
        final data = e.response?.data;
        final conflict =
            data is Map && data['error'] == 'device_list_version_conflict';
        // Two edits at once (spec Part C): load the newer list and sign
        // version + 1 of it. Bounded, so a server that keeps answering 409
        // produces an error instead of a loop.
        if (!conflict || attempt == 3) rethrow;
        await checkOwnList(directory.selfDeviceId);
      }
    }
    await checkOwnList(directory.selfDeviceId);
    _notify();
  }

  Future<void> _ensureSession(String deviceId) async {
    if (!await _sessions.hasSession(deviceId)) {
      await _sessions.initiateSession(
        deviceId,
        await _api.getKeyBundle(deviceId),
      );
    }
  }

  void _setStatus(CompanionStatus status) {
    _status = status;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _emit(OwnLinkEvent event) {
    if (!_ownLinks.isClosed) _ownLinks.add(event);
  }

  @override
  void dispose() {
    _disposed = true;
    _changes?.cancel();
    _hints?.cancel();
    _ownLinks.close();
    super.dispose();
  }
}
