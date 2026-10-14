import 'dart:convert';

import 'package:calltype_core/crypto/device_list.dart';
import 'package:calltype_core/devices/device_directory.dart';
import 'package:calltype_core/devices/fanout_sender.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:drift/drift.dart';
import 'package:test/test.dart';

import '../helpers/test_device.dart';

const me = '10000000-0000-4000-8000-000000000001';
const bob = '20000000-0000-4000-8000-000000000002';
const bobWeb = '20000000-0000-4000-8000-000000000003';
const rogue = '90000000-0000-4000-8000-000000000009';

class ListApi extends ApiClient {
  ListApi() : super(baseUrl: 'http://unused');
  final served = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, dynamic>?> getDeviceList(String deviceId) async =>
      served[deviceId];
}

void main() {
  late TestDevice self;
  late Map<String, TestDevice> peers;
  late ListApi api;
  late DeviceDirectory directory;
  late FanoutSender sender;

  Future<void> ensureSession(String peer) async {
    if (!await self.sessions.hasSession(peer)) {
      await self.sessions.initiateSession(peer, await peers[peer]!.keyBundle());
    }
  }

  Future<void> serveBobList(int version, List<String> companions) async {
    final primary = peers[bob]!;
    final signed = await signDeviceList(
      primarySigningKey: await primary.keys.getSigningKeyPair(),
      list: DeviceList(
        primaryDeviceId: bob,
        version: version,
        devices: [
          for (final id in companions)
            DeviceListEntry(
              deviceId: id,
              identityKey: await peers[id]!.keys.getPublicIdentityKey(),
              signingKey:
                  (await peers[id]!.keys.getSignedIdentityBundle())['signingKey']!,
              consentSig: await signDeviceLinkConsent(
                companionSigningKey: await peers[id]!.keys.getSigningKeyPair(),
                primaryDeviceId: bob,
                companionDeviceId: id,
              ),
            ),
        ],
      ),
    );
    api.served[bob] = {
      'primaryDeviceId': bob,
      'version': version,
      'payload': signed.payload,
      'signature': signed.signature,
    };
  }

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    self = await TestDevice.create(me);
    peers = {
      for (final id in [bob, bobWeb, rogue]) id: await TestDevice.create(id),
    };
    api = ListApi();
    directory = DeviceDirectory(
      database: self.db,
      apiClient: api,
      selfDeviceId: me,
      selfSigningKey: () async =>
          (await self.keys.getSignedIdentityBundle())['signingKey']!,
      selfIdentityKey: self.keys.getPublicIdentityKey,
    );
    await directory.load();
    sender = FanoutSender(
      directory: directory,
      sessions: self.sessions,
      ensureSession: ensureSession,
    );
  });

  tearDown(() async {
    await self.close();
    for (final peer in peers.values) {
      await peer.close();
    }
  });

  final payload = jsonEncode({'v': 1, 'id': 'm', 'body': 'hi', 'groupId': null});

  test('encrypts one envelope per verified device, each decryptable', () async {
    await serveBobList(1, [bobWeb]);
    final envelopes = await sender.encrypt([bob], payload);
    expect(envelopes.keys, unorderedEquals([bob, bobWeb]));
    for (final id in [bob, bobWeb]) {
      final plain = await peers[id]!.sessions.decryptMessage(
        me,
        utf8.decode(base64Decode(envelopes[id]!)),
      );
      expect(jsonDecode(plain)['body'], 'hi');
    }
  });

  test('stale: a device the server no longer has is dropped, others resent as is', () async {
    await serveBobList(1, [bobWeb]);
    final first = await sender.encrypt([bob], payload);
    final fixed = await sender.reconcile(
      envelopes: first,
      required: {bob},
      identityIds: [bob],
      payload: payload,
    );
    expect(fixed.keys, [bob]);
    // Byte-identical: re-encrypting would advance the ratchet a second time.
    expect(fixed[bob], first[bob]);
  });

  test('stale: a newly listed device gets an envelope after the list verifies', () async {
    await serveBobList(1, []);
    final first = await sender.encrypt([bob], payload);
    expect(first.keys, [bob]);
    await serveBobList(2, [bobWeb]);
    final fixed = await sender.reconcile(
      envelopes: first,
      required: {bob, bobWeb},
      identityIds: [bob],
      payload: payload,
    );
    expect(fixed.keys, unorderedEquals([bob, bobWeb]));
    expect(fixed[bob], first[bob]);
  });

  test('stale: a device the server demands but nobody signed is refused', () async {
    await serveBobList(1, []);
    final first = await sender.encrypt([bob], payload);
    expect(
      sender.reconcile(
        envelopes: first,
        required: {bob, rogue},
        identityIds: [bob],
        payload: payload,
      ),
      throwsA(isA<DeviceListException>()),
    );
  });
}
