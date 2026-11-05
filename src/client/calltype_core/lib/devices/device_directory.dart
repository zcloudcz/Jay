import 'dart:async';

import '../crypto/device_list.dart';
import '../network/api_client.dart';
import '../storage/database.dart';

/// What changed in an identity's device list (drives the "contact added a
/// device" notice).
class DeviceListChange {
  const DeviceListChange({
    required this.identityId,
    required this.added,
    required this.removed,
    this.firstList = false,
  });
  final String identityId;
  final Set<String> added;
  final Set<String> removed;

  /// True when nothing was stored for this identity before: the first fetch
  /// of a list that may have existed for a long time. Its devices are not
  /// news to the user, so the app shows no "added a device" line for it.
  final bool firstList;
}

/// Where an incoming message belongs.
class InboundRoute {
  const InboundRoute({
    required this.conversationId,
    required this.senderIdentityId,
    required this.own,
  });
  final String conversationId;

  /// What to store in `messages.senderId`: the identity, never a companion's
  /// device id, so "mine vs theirs", delete-for-everyone and reply quotes
  /// keep working without knowing about devices.
  final String senderIdentityId;

  /// True for a copy of a message another of OUR devices sent.
  final bool own;
}

/// This device's view of who owns which device.
///
/// "Identity" is the primary device id: the id contacts, conversations and
/// `messages.senderId` use. Everything here is local and verified; the only
/// network call is [refresh], and what it fetches is checked against a key
/// this device pinned itself before it is stored.
class DeviceDirectory {
  DeviceDirectory({
    required AppDatabase database,
    required ApiClient apiClient,
    required String selfDeviceId,
    required Future<String> Function() selfSigningKey,
    required Future<String> Function() selfIdentityKey,
  }) : _db = database,
       _api = apiClient,
       _selfSigningKey = selfSigningKey,
       _selfIdentityKey = selfIdentityKey,
       // Ids are compared as strings everywhere below and the codec only
       // accepts lowercase, so a differently-cased id would never match.
       selfDeviceId = selfDeviceId.toLowerCase(),
       _selfIdentityId = selfDeviceId.toLowerCase();

  final AppDatabase _db;
  final ApiClient _api;
  final Future<String> Function() _selfSigningKey;

  /// Base64 public X25519 identity key of this device (callers pass
  /// `keyManager.getPublicIdentityKey`).
  final Future<String> Function() _selfIdentityKey;

  /// Serializes [refresh]: two overlapping refreshes (push event plus manual
  /// pull) must not interleave their read-verify-write steps.
  Future<void> _tail = Future.value();

  final _changes = StreamController<DeviceListChange>.broadcast();

  /// Every change [refresh] stored, whoever asked for it (inbox, outbox
  /// reconcile, a DeviceListChanged hint). The app derives the "contact added
  /// a device" line and the companion wipe from this ONE stream: callers such
  /// as FanoutSender.reconcile refresh internally and do not hand their
  /// changes back.
  Stream<DeviceListChange> get changes => _changes.stream;

  /// The transport address of this device (hub connection, sessions).
  final String selfDeviceId;

  String _selfIdentityId;

  /// "Me" in conversations. Equals [selfDeviceId] unless this device is a
  /// companion. Call [load] once at startup before reading it.
  String get selfIdentityId => _selfIdentityId;

  bool get isCompanion => _selfIdentityId != selfDeviceId;

  Future<void> load() async {
    _selfIdentityId = await identityOf(selfDeviceId);
  }

  Future<String> identityOf(String deviceId) async {
    deviceId = deviceId.toLowerCase();
    final row = await (_db.select(
      _db.knownDeviceListMembers,
    )..where((m) => m.deviceId.equals(deviceId))).getSingleOrNull();
    return row?.primaryDeviceId ?? deviceId;
  }

  /// The primary first, then its verified companions.
  Future<List<String>> devicesOf(String identityId) async {
    identityId = identityId.toLowerCase();
    final rows = await (_db.select(
      _db.knownDeviceListMembers,
    )..where((m) => m.primaryDeviceId.equals(identityId))).get();
    return [identityId, ...rows.map((r) => r.deviceId)];
  }

  /// Every device a message to [identityIds] must be encrypted for: all
  /// their devices plus our own other devices (so they see what we sent).
  Future<List<String>> fanoutTargets(Iterable<String> identityIds) async {
    final targets = <String>{};
    for (final id in {
      ...identityIds.map((i) => i.toLowerCase()),
      _selfIdentityId,
    }) {
      targets.addAll(await devicesOf(id));
    }
    targets.remove(selfDeviceId);
    return targets.toList();
  }

  /// Fetches the list [deviceId] is in and stores it if, and only if, it
  /// verifies. [deviceId] may be any device id: it is resolved to the identity
  /// it is CURRENTLY attributed to and that identity's list is fetched, so a
  /// removed companion (which the server no longer finds in any list) still
  /// gets its stale attribution replaced. Returns what changed, or null when there is no list or it is
  /// the one already stored.
  ///
  /// [ensurePinned] must make sure the PRIMARY's identity is pinned (start a
  /// session with it). Only called when no pin exists yet: that is the same
  /// trust-on-first-use moment as a first message to a new contact.
  ///
  /// [ensurePinned] must not call [refresh] on this directory: calls are
  /// serialized, so a nested refresh would wait for itself forever.
  ///
  /// A device attributed to identity A moves to B only after A's list was
  /// refreshed without it; a caller that hits
  /// `device_claimed_by_other_identity` should refresh the old owner first.
  ///
  /// Throws [DeviceListException] when the server serves something that does
  /// not verify. What was stored before stays untouched in that case, and a
  /// missing list never deletes a stored one: otherwise the server could
  /// shrink or wipe a verified list by lying.
  Future<DeviceListChange?> refresh(
    String deviceId, {
    required Future<void> Function(String primaryDeviceId) ensurePinned,
  }) {
    final run = _tail.then((_) => _refresh(deviceId, ensurePinned));
    // The chain survives a failed refresh; the caller still gets the error.
    _tail = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<DeviceListChange?> _refresh(
    String deviceId,
    Future<void> Function(String primaryDeviceId) ensurePinned,
  ) async {
    deviceId = deviceId.toLowerCase();
    // A removed companion is in no list any more, so the server answers 404 for
    // its own id and a missing list never deletes a stored one: the device
    // would stay attributed to its old owner forever. Asking for the stored
    // owner's list instead returns the newer list without it.
    final fetchId = await identityOf(deviceId);
    final raw = await _api.getDeviceList(fetchId);
    if (raw == null) return null;
    final primary = (raw['primaryDeviceId'] as String).toLowerCase();
    final signed = SignedDeviceList(
      raw['payload'] as String,
      raw['signature'] as String,
    );
    final stored = await (_db.select(
      _db.knownDeviceLists,
    )..where((l) => l.primaryDeviceId.equals(primary))).getSingleOrNull();
    if (stored != null &&
        stored.payload == signed.payload &&
        stored.signature == signed.signature) {
      return null;
    }
    final list = await verifyDeviceList(
      signed: signed,
      primarySigningKey: await _signingKeyOf(primary, ensurePinned),
      expectedPrimaryDeviceId: primary,
      minVersion: (stored?.version ?? 0) + 1,
    );
    final before = (await devicesOf(primary)).toSet()..remove(primary);
    final after = list.devices.map((d) => d.deviceId).toSet();
    // Being listed makes THIS device a companion, so the list must carry our
    // real keys. The entry's own consent signature proves nothing about us:
    // the attacker chooses the key it was made with. Only our keys can.
    for (final entry in list.devices) {
      if (entry.deviceId != selfDeviceId) continue;
      if (entry.identityKey != await _selfIdentityKey() ||
          entry.signingKey != await _selfSigningKey()) {
        throw const DeviceListException('self_not_consented');
      }
    }
    // The server answers "the list of X" from its own records, so it can hand
    // back any validly signed list (e.g. an attacker's). Only a list that
    // actually concerns the device we asked about (or the identity it was
    // resolved to) may change our view.
    if (primary != deviceId && primary != fetchId && !after.contains(deviceId)) {
      throw const DeviceListException('unrelated_list');
    }
    await _db.transaction(() async {
      final current = await (_db.select(
        _db.knownDeviceLists,
      )..where((l) => l.primaryDeviceId.equals(primary))).getSingleOrNull();
      if (current != null && current.version >= list.version) {
        throw const DeviceListException('rollback');
      }
      // Attribution to another identity must never be forced by a list that
      // other identity did not sign. A device may move between identities
      // only after its old owner's list was refreshed without it.
      for (final device in after) {
        if (await _isClaimedElsewhere(device, primary)) {
          throw const DeviceListException('device_claimed_by_other_identity');
        }
      }
      // Same check as assertListedKeys, moved to write time: a list must never
      // claim a device whose real keys we already pinned (e.g. Bob messaged us
      // first and a hostile list now names him with the attacker's keys).
      // Stored once, such a list would attribute him to the attacker for good.
      for (final entry in list.devices) {
        final pinned = await _pinOf(entry.deviceId);
        if (pinned != null &&
            pinned != '${entry.identityKey}|${entry.signingKey}') {
          throw const DeviceListException('listed_keys_mismatch');
        }
      }
      await _db
          .into(_db.knownDeviceLists)
          .insertOnConflictUpdate(
            KnownDeviceListsCompanion.insert(
              primaryDeviceId: primary,
              version: list.version,
              payload: signed.payload,
              signature: signed.signature,
            ),
          );
      await (_db.delete(
        _db.knownDeviceListMembers,
      )..where((m) => m.primaryDeviceId.equals(primary))).go();
      for (final device in list.devices) {
        await _db
            .into(_db.knownDeviceListMembers)
            .insert(
              KnownDeviceListMembersCompanion.insert(
                deviceId: device.deviceId,
                primaryDeviceId: primary,
              ),
            );
      }
    });
    // Our own membership may just have changed (linked or removed).
    if (before.contains(selfDeviceId) || after.contains(selfDeviceId)) {
      await load();
    }
    final change = DeviceListChange(
      identityId: primary,
      added: after.difference(before),
      removed: before.difference(after),
      // `stored` is safe to use here: refreshes are serialized, and the
      // transaction above re-checked that nothing newer arrived meanwhile.
      firstList: stored == null,
    );
    _changes.add(change);
    return change;
  }

  /// True when [device] already belongs to an identity other than [primary]:
  /// it is a companion of someone else, or it is itself a primary we know
  /// (a stored list, a contact, or our own identity when we are a companion).
  Future<bool> _isClaimedElsewhere(String device, String primary) async {
    if (device == primary) return true;
    final member = await (_db.select(
      _db.knownDeviceListMembers,
    )..where((m) => m.deviceId.equals(device))).getSingleOrNull();
    if (member != null && member.primaryDeviceId != primary) return true;
    final list = await (_db.select(
      _db.knownDeviceLists,
    )..where((l) => l.primaryDeviceId.equals(device))).getSingleOrNull();
    if (list != null) return true;
    final contact = await (_db.select(
      _db.contacts,
    )..where((c) => c.deviceId.equals(device))).getSingleOrNull();
    if (contact != null) return true;
    return isCompanion && device == _selfIdentityId;
  }

  /// Decides the conversation and the stored sender for an incoming message.
  /// [to] comes from INSIDE the decrypted payload and is honoured only for
  /// copies sent by our own devices; a peer cannot steer a message into
  /// another conversation with it.
  ///
  /// Callers must [refresh] the sender first: a companion whose list was never
  /// fetched is treated as its own identity.
  Future<InboundRoute> routeInbound({
    required String senderDeviceId,
    String? groupId,
    String? to,
  }) async {
    final sender = await identityOf(senderDeviceId);
    final own = sender == _selfIdentityId;
    if (own && groupId == null && to == null) {
      throw const DeviceListException('own_copy_without_to');
    }
    return InboundRoute(
      conversationId: groupId ?? (own ? to! : sender),
      senderIdentityId: sender,
      own: own,
    );
  }

  /// `<identityKey>|<signingKey>` that the signed list holds for the listed
  /// companion [deviceId], in the format of the pin; null when the device is
  /// not a listed companion (a primary is pinned directly, on first contact).
  /// Lets a caller check a key bundle BEFORE pinning it: a pin cannot be
  /// taken back, see [assertListedKeys].
  Future<String?> expectedKeysOf(String deviceId) async {
    deviceId = deviceId.toLowerCase();
    final identity = await identityOf(deviceId);
    if (identity == deviceId) return null;
    final stored = await (_db.select(
      _db.knownDeviceLists,
    )..where((l) => l.primaryDeviceId.equals(identity))).getSingleOrNull();
    if (stored == null) return null;
    for (final d in parseDeviceListPayload(stored.payload).devices) {
      if (d.deviceId == deviceId) return '${d.identityKey}|${d.signingKey}';
    }
    return null;
  }

  /// Throws when the keys this device pinned for a companion (at session
  /// start) are not the keys its primary signed into the list. Catches a
  /// server that swaps a companion's key bundle, and a signer who lists a
  /// stranger's device id with a key pair of her own (consent only proves
  /// that the key written in the entry agreed).
  ///
  /// Call it only after a session with [deviceId] exists: both session paths
  /// pin (initiateSession, and decryptMessage for a pre-key message). No pin
  /// means nothing ties the entry to the device, so it fails closed.
  Future<void> assertListedKeys(String deviceId) async {
    deviceId = deviceId.toLowerCase();
    final identity = await identityOf(deviceId);
    if (identity == deviceId) return; // a primary: pinned directly, not listed
    final pinned = await _pinOf(deviceId);
    if (pinned == null) {
      throw const DeviceListException('listed_device_not_pinned');
    }
    final stored = await (_db.select(
      _db.knownDeviceLists,
    )..where((l) => l.primaryDeviceId.equals(identity))).getSingleOrNull();
    if (stored == null) {
      throw const DeviceListException('listed_device_unknown');
    }
    final entry = parseDeviceListPayload(stored.payload).devices.firstWhere(
      (d) => d.deviceId == deviceId,
      orElse: () => throw const DeviceListException('listed_device_unknown'),
    );
    if (pinned != '${entry.identityKey}|${entry.signingKey}') {
      throw const DeviceListException('listed_keys_mismatch');
    }
  }

  Future<String?> _pinOf(String deviceId) async => (await (_db.select(
    _db.backupState,
  )..where((r) => r.key.equals('peer_identity:$deviceId'))).getSingleOrNull())
      ?.value;

  Future<String> _signingKeyOf(
    String primary,
    Future<void> Function(String) ensurePinned,
  ) async {
    if (primary == selfDeviceId) return _selfSigningKey();
    var pinned = await _pinOf(primary);
    if (pinned == null) {
      await ensurePinned(primary);
      pinned = await _pinOf(primary);
    }
    if (pinned == null) throw const DeviceListException('primary_not_pinned');
    // Stored by SessionManager as "<identityKey>|<signingKey>".
    return pinned.split('|')[1];
  }
}
