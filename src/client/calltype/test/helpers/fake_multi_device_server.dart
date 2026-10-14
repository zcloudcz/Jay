import 'dart:async';

import 'package:calltype/core/network/api_client.dart';
import 'package:calltype/core/network/signalr_client.dart';
import 'package:calltype/features/devices/device_service.dart';
import 'package:calltype_core/crypto/device_list.dart';
import 'package:calltype_core/devices/device_directory.dart';
import 'package:dio/dio.dart';

import 'test_device.dart';

/// In-memory stand-in for the parts of the API and hub that multi-device
/// needs. Like the real server it stores device lists as opaque signed bytes
/// and never verifies them, and its fan-out completeness check mirrors
/// MessengerHub.FanoutAsync, so clients are tested against the real rules.
class FakeMultiDeviceServer {
  final devices = <String, TestDevice>{};

  /// primary id -> the GET /devices/{id}/device-list body.
  final lists = <String, Map<String, dynamic>>{};

  /// companion id -> primary id (the server's DeviceListMembers).
  final members = <String, String>{};
  final groups = <String, List<String>>{};
  final inboxes = <String, StreamController<Map<String, dynamic>>>{};

  /// Every device id a client asked the list for, in order.
  final deviceListRequests = <String>[];
  final hubs = <String, FakeHubClient>{};
  final _services = <DeviceService>[];

  void add(TestDevice device) {
    devices[device.id] = device;
    inboxes[device.id] = StreamController<Map<String, dynamic>>();
  }

  String primaryOf(String deviceId) => members[deviceId] ?? deviceId;

  Set<String> devicesOf(String identityId) => {
    identityId,
    for (final e in members.entries)
      if (e.value == identityId) e.key,
  };

  /// The GET body of [primaryId]'s list, signed by [signer], naming
  /// [entries] as (device id, device whose keys and consent go into the entry).
  Future<Map<String, dynamic>> signedList(
    TestDevice signer,
    String primaryId,
    int version,
    List<(String, TestDevice)> entries,
  ) async {
    final signed = await signDeviceList(
      primarySigningKey: await signer.keys.getSigningKeyPair(),
      list: DeviceList(
        primaryDeviceId: primaryId,
        version: version,
        devices: [
          for (final (id, owner) in entries)
            DeviceListEntry(
              deviceId: id,
              identityKey: await owner.keys.getPublicIdentityKey(),
              signingKey:
                  (await owner.keys.getSignedIdentityBundle())['signingKey']!,
              consentSig: await signDeviceLinkConsent(
                companionSigningKey: await owner.keys.getSigningKeyPair(),
                primaryDeviceId: primaryId,
                companionDeviceId: id,
              ),
            ),
        ],
      ),
    );
    return {
      'primaryDeviceId': primaryId,
      'version': version,
      'payload': signed.payload,
      'signature': signed.signature,
    };
  }

  /// [primary] signs a list of [companions], as a successful PUT would store it.
  Future<void> link(
    TestDevice primary,
    List<TestDevice> companions, {
    required int version,
  }) async => store(
    await signedList(primary, primary.id, version, [
      for (final c in companions) (c.id, c),
    ]),
  );

  void store(Map<String, dynamic> body) {
    final primary = body['primaryDeviceId'] as String;
    lists[primary] = body;
    members.removeWhere((_, p) => p == primary);
    for (final d in parseDeviceListPayload(body['payload'] as String).devices) {
      members[d.deviceId] = primary;
    }
  }

  /// MessengerHub.FanoutAsync: the declared devices must be exactly every
  /// device of the target identities and of the sender's own identity, minus
  /// the sending device; otherwise `device_list_stale:<required>`.
  void fanout({
    required String sender,
    required Set<String> identities,
    required String messageId,
    required Map<String, String> payloads,
    String? groupId,
  }) {
    final required = <String>{
      for (final identity in {...identities, primaryOf(sender)})
        ...devicesOf(identity),
    }..remove(sender);
    final declared = payloads.keys.toSet();
    if (declared.length != required.length || !declared.containsAll(required)) {
      throw Exception('HubException: device_list_stale:${required.join(',')}');
    }
    for (final entry in payloads.entries) {
      inboxes[entry.key]?.add({
        'senderId': sender,
        'messageId': messageId,
        'encryptedBody': entry.value,
        'groupId': groupId,
      });
    }
  }

  /// [device]'s view of device lists, against this server.
  DeviceDirectory directoryFor(TestDevice device) => DeviceDirectory(
    database: device.db,
    apiClient: FakeDeviceApi(this),
    selfDeviceId: device.id,
    selfSigningKey: () async =>
        (await device.keys.getSignedIdentityBundle())['signingKey']!,
    selfIdentityKey: device.keys.getPublicIdentityKey,
  );

  /// What a first message does before a list can be verified: a session with
  /// the primary, which pins its keys.
  Future<void> Function(String) pinFor(TestDevice device) => (id) async {
    if (!await device.sessions.hasSession(id)) {
      await device.sessions.initiateSession(id, await devices[id]!.keyBundle());
    }
  };

  /// An opened DeviceService for [device]; its hub is [hubs][device.id].
  Future<DeviceService> deviceServiceFor(TestDevice device) async {
    final hub = hubs[device.id] = FakeHubClient(this, device.id);
    final service = DeviceService(
      database: device.db,
      apiClient: FakeDeviceApi(this),
      keyManager: device.keys,
      sessionManager: device.sessions,
      signalRClient: hub,
    );
    await service.open(device.id);
    _services.add(service);
    return service;
  }

  Future<void> close() async {
    for (final service in _services) {
      service.dispose();
    }
    for (final hub in hubs.values) {
      hub.dispose();
    }
    // Not awaited: close() of a single-subscription controller that never
    // had a listener completes only when somebody listens, i.e. never.
    for (final inbox in inboxes.values) {
      unawaited(inbox.close());
    }
  }
}

class FakeDeviceApi extends ApiClient {
  FakeDeviceApi(this.server) : super(baseUrl: 'http://unused');
  final FakeMultiDeviceServer server;

  @override
  Future<Map<String, dynamic>> getKeyBundle(String deviceId) =>
      server.devices[deviceId]!.keyBundle();

  @override
  Future<Map<String, dynamic>?> getDeviceList(String deviceId) async {
    server.deviceListRequests.add(deviceId);
    return server.lists[server.primaryOf(deviceId)];
  }

  /// Only the rule the client must handle (version must grow); the consent
  /// and membership rules are covered by the server's own tests.
  @override
  Future<void> putDeviceList(
    String primaryDeviceId, {
    required String payload,
    required String signature,
  }) async {
    final version = parseDeviceListPayload(payload).version;
    final current = server.lists[primaryDeviceId]?['version'] as int?;
    if (current != null && version <= current) {
      final request = RequestOptions(path: '/devices/$primaryDeviceId/device-list');
      throw DioException(
        requestOptions: request,
        response: Response(
          requestOptions: request,
          statusCode: 409,
          data: {'error': 'device_list_version_conflict'},
        ),
      );
    }
    server.store({
      'primaryDeviceId': primaryDeviceId,
      'version': version,
      'payload': payload,
      'signature': signature,
    });
  }

  @override
  Future<List<String>> getGroupMembers(String groupId) async =>
      server.groups[groupId]!;
}

/// The app's SignalRClient with the hub replaced by [FakeMultiDeviceServer]
/// and the link / list events injectable by the test.
class FakeHubClient extends SignalRClient {
  FakeHubClient(this.server, String deviceId)
    : super(baseUrl: 'http://unused', deviceId: deviceId);
  final FakeMultiDeviceServer server;
  final offers = StreamController<Map<String, dynamic>>.broadcast();
  final consents = StreamController<Map<String, dynamic>>.broadcast();
  final listChanged = StreamController<Map<String, dynamic>>.broadcast();
  final sentOffers = <String>[];
  final sentConsents = <(String, String)>[];
  final acks = <String>[];

  @override
  Stream<Map<String, dynamic>> get onLinkOffer => offers.stream;
  @override
  Stream<Map<String, dynamic>> get onLinkConsent => consents.stream;
  @override
  Stream<Map<String, dynamic>> get onDeviceListChanged => listChanged.stream;

  @override
  Future<void> sendDirectFanout(
    String recipientIdentityId,
    Map<String, String> encryptedPayloads, {
    required String messageId,
  }) async => server.fanout(
    sender: deviceId,
    identities: {recipientIdentityId},
    messageId: messageId,
    payloads: encryptedPayloads,
  );

  @override
  Future<void> sendGroupFanout(
    String groupId,
    Map<String, String> encryptedPayloads, {
    required String messageId,
  }) async => server.fanout(
    sender: deviceId,
    identities: server.groups[groupId]!.toSet(),
    messageId: messageId,
    payloads: encryptedPayloads,
    groupId: groupId,
  );

  @override
  Future<void> acknowledgeMessage(String senderId, String messageId) async =>
      acks.add(messageId);

  @override
  Future<void> sendLinkOffer(String targetDeviceId) async =>
      sentOffers.add(targetDeviceId);

  @override
  Future<void> sendLinkConsent(String primaryDeviceId, String consentSig) async =>
      sentConsents.add((primaryDeviceId, consentSig));

  @override
  void dispose() {
    offers.close();
    consents.close();
    listChanged.close();
    super.dispose();
  }
}

/// Polls [condition]. DeviceService reacts to list changes on a stream, so
/// tests wait for the effect instead of guessing how many event-loop turns
/// it takes. Plain `test()` only (real time).
Future<void> until(FutureOr<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition never held');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
