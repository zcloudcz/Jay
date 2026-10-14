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
  });
  final String identityId;
  final Set<String> added;
  final Set<String> removed;
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
    required this.selfDeviceId,
    required Future<String> Function() selfSigningKey,
  }) : _db = database,
       _api = apiClient,
       _selfSigningKey = selfSigningKey,
       _selfIdentityId = selfDeviceId;

  final AppDatabase _db;
  final ApiClient _api;
  final Future<String> Function() _selfSigningKey;

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
    final row = await (_db.select(
      _db.knownDeviceListMembers,
    )..where((m) => m.deviceId.equals(deviceId))).getSingleOrNull();
    return row?.primaryDeviceId ?? deviceId;
  }

  /// The primary first, then its verified companions.
  Future<List<String>> devicesOf(String identityId) async {
    final rows = await (_db.select(
      _db.knownDeviceListMembers,
    )..where((m) => m.primaryDeviceId.equals(identityId))).get();
    return [identityId, ...rows.map((r) => r.deviceId)];
  }

  /// Every device a message to [identityIds] must be encrypted for: all
  /// their devices plus our own other devices (so they see what we sent).
  Future<List<String>> fanoutTargets(Iterable<String> identityIds) async {
    final targets = <String>{};
    for (final id in {...identityIds, _selfIdentityId}) {
      targets.addAll(await devicesOf(id));
    }
    targets.remove(selfDeviceId);
    return targets.toList();
  }

  /// Fetches the list [deviceId] is in and stores it if, and only if, it
  /// verifies. Returns what changed, or null when there is no list or it is
  /// the one already stored.
  ///
  /// [ensurePinned] must make sure the PRIMARY's identity is pinned (start a
  /// session with it). Only called when no pin exists yet: that is the same
  /// trust-on-first-use moment as a first message to a new contact.
  ///
  /// Throws [DeviceListException] when the server serves something that does
  /// not verify. What was stored before stays untouched in that case, and a
  /// missing list never deletes a stored one: otherwise the server could
  /// shrink or wipe a verified list by lying.
  Future<DeviceListChange?> refresh(
    String deviceId, {
    required Future<void> Function(String primaryDeviceId) ensurePinned,
  }) async {
    final raw = await _api.getDeviceList(deviceId);
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
    await _db.transaction(() async {
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
            .insertOnConflictUpdate(
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
    return DeviceListChange(
      identityId: primary,
      added: after.difference(before),
      removed: before.difference(after),
    );
  }

  /// Decides the conversation and the stored sender for an incoming message.
  /// [to] comes from INSIDE the decrypted payload and is honoured only for
  /// copies sent by our own devices; a peer cannot steer a message into
  /// another conversation with it.
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
    final identity = await identityOf(deviceId);
    if (identity == deviceId) return; // a primary: pinned directly, not listed
    final pinned = await _pinOf(deviceId);
    if (pinned == null) {
      throw const DeviceListException('listed_device_not_pinned');
    }
    final stored = await (_db.select(
      _db.knownDeviceLists,
    )..where((l) => l.primaryDeviceId.equals(identity))).getSingle();
    final entry = parseDeviceListPayload(
      stored.payload,
    ).devices.firstWhere((d) => d.deviceId == deviceId);
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
