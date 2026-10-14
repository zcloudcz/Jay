import 'dart:convert';

import 'package:calltype_core/crypto/device_list.dart';
import 'package:calltype_core/devices/device_directory.dart';
import 'package:calltype_core/devices/fanout_sender.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:test/test.dart';

import '../helpers/test_device.dart';

const me = '10000000-0000-4000-8000-000000000001';
const mySibling = '10000000-0000-4000-8000-000000000004';
const bob = '20000000-0000-4000-8000-000000000002';
const bobWeb = '20000000-0000-4000-8000-000000000003';
const carol = '30000000-0000-4000-8000-000000000005';
const rogue = '90000000-0000-4000-8000-000000000009';

/// Plays the server: serves signed lists and key bundles. A bundle can be
/// swapped to simulate a hostile server.
class ServerApi extends ApiClient {
  ServerApi(this.peers) : super(baseUrl: 'http://unused');
  final Map<String, TestDevice> peers;
  final served = <String, Map<String, dynamic>>{};

  /// deviceId -> peer whose bundle is served instead of its own.
  final bundleFrom = <String, String>{};

  @override
  Future<Map<String, dynamic>?> getDeviceList(String deviceId) async {
    onGetDeviceList?.call(deviceId);
    return served[deviceId];
  }

  /// Lets a test count list fetches.
  void Function(String)? onGetDeviceList;

  @override
  Future<Map<String, dynamic>> getKeyBundle(String deviceId) =>
      peers[bundleFrom[deviceId] ?? deviceId]!.keyBundle();
}

void main() {
  late TestDevice self;
  late Map<String, TestDevice> peers;
  late ServerApi api;
  late DeviceDirectory directory;
  late FanoutSender sender;

  /// Serves [owner]'s list with [companions]. [signer] defaults to the owner.
  Future<void> serveList(
    String owner,
    int version,
    List<String> companions, {
    String? signer,
  }) async {
    final all = {...peers, me: self};
    final signed = await signDeviceList(
      primarySigningKey: await all[signer ?? owner]!.keys.getSigningKeyPair(),
      list: DeviceList(
        primaryDeviceId: owner,
        version: version,
        devices: [
          for (final id in companions)
            DeviceListEntry(
              deviceId: id,
              identityKey: await all[id]!.keys.getPublicIdentityKey(),
              signingKey:
                  (await all[id]!.keys.getSignedIdentityBundle())['signingKey']!,
              consentSig: await signDeviceLinkConsent(
                companionSigningKey: await all[id]!.keys.getSigningKeyPair(),
                primaryDeviceId: owner,
                companionDeviceId: id,
              ),
            ),
        ],
      ),
    );
    api.served[owner] = {
      'primaryDeviceId': owner,
      'version': version,
      'payload': signed.payload,
      'signature': signed.signature,
    };
  }

  Future<void> serveBobList(int version, List<String> companions) =>
      serveList(bob, version, companions);

  Future<String?> pinOf(String id) async => (await (self.db.select(
    self.db.backupState,
  )..where((r) => r.key.equals('peer_identity:$id'))).getSingleOrNull())?.value;

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    self = await TestDevice.create(me);
    peers = {
      for (final id in [bob, bobWeb, carol, rogue, mySibling])
        id: await TestDevice.create(id),
    };
    api = ServerApi(peers);
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
      apiClient: api,
    );
  });

  tearDown(() async {
    await self.close();
    for (final peer in peers.values) {
      await peer.close();
    }
  });

  final payload = jsonEncode({'v': 1, 'id': 'm', 'body': 'hi', 'groupId': null});

  Future<String> open(String device, Map<String, String> envelopes) async =>
      peers[device]!.sessions.decryptMessage(
        me,
        utf8.decode(base64Decode(envelopes[device]!)),
      );

  /// What the app does on a first send to a multi-device identity: encrypt to
  /// the stored state, then the hub answers device_list_stale with [required].
  Future<Map<String, String>> sendThenReconcile(
    List<String> identities,
    Set<String> required,
  ) async {
    final first = await sender.encrypt(identities, payload);
    return sender.reconcile(
      envelopes: first,
      required: required,
      identityIds: identities,
      payload: payload,
    );
  }

  test('encrypt alone makes no network fetch and covers known devices',
      () async {
    var listFetches = 0;
    api.onGetDeviceList = (_) => listFetches++;
    await serveBobList(1, [bobWeb]);
    await serveList(carol, 1, [], signer: rogue); // would not verify
    final envelopes = await sender.encrypt([bob, carol], payload);
    // Nothing fetched yet, so only the primaries are known.
    expect(envelopes.keys, unorderedEquals([bob, carol]));
    expect(listFetches, 0);
  });

  test('first send to a multi-device identity: stale then reconcile adds it',
      () async {
    await serveBobList(1, [bobWeb]);
    final envelopes = await sendThenReconcile([bob], {bob, bobWeb});
    expect(envelopes.keys, unorderedEquals([bob, bobWeb]));
    for (final id in [bob, bobWeb]) {
      expect(jsonDecode(await open(id, envelopes))['body'], 'hi');
    }
    // Afterwards encrypt covers both without any fetch.
    final next = await sender.encrypt([bob], payload);
    expect(next.keys, unorderedEquals([bob, bobWeb]));
  });

  test('a group send covers the devices of every identity', () async {
    await serveBobList(1, [bobWeb]);
    final envelopes = await sendThenReconcile([bob, carol], {
      bob,
      bobWeb,
      carol,
    });
    expect(envelopes.keys, unorderedEquals([bob, bobWeb, carol]));
  });

  test('our own other device gets a decryptable copy', () async {
    await serveList(me, 1, [mySibling]);
    // Our own list is loaded by the app (not by encrypt).
    await directory.refresh(me, ensurePinned: (_) async {});
    final envelopes = await sender.encrypt([bob], payload);
    expect(envelopes.keys, unorderedEquals([bob, mySibling]));
    expect(jsonDecode(await open(mySibling, envelopes))['body'], 'hi');
  });

  test('stale: one bad list does not block a missing device of another identity',
      () async {
    await serveBobList(1, []);
    await serveList(carol, 1, [], signer: rogue); // badly signed
    final first = await sender.encrypt([bob, carol], payload);
    await serveBobList(2, [bobWeb]);
    final fixed = await sender.reconcile(
      envelopes: first,
      required: {bob, bobWeb, carol},
      identityIds: [bob, carol],
      payload: payload,
    );
    expect(fixed.keys, unorderedEquals([bob, bobWeb, carol]));
  });

  test('a swapped companion bundle is refused without pinning, then recovers',
      () async {
    await serveBobList(1, [bobWeb]);
    final first = await sender.encrypt([bob], payload);
    api.bundleFrom[bobWeb] = rogue;
    await expectLater(
      sender.reconcile(
        envelopes: first,
        required: {bob, bobWeb},
        identityIds: [bob],
        payload: payload,
      ),
      throwsA(
        isA<DeviceListException>().having(
          (e) => e.reason,
          'reason',
          'listed_keys_mismatch',
        ),
      ),
    );
    expect(await self.sessions.hasSession(bobWeb), isFalse);
    expect(await pinOf(bobWeb), isNull);

    api.bundleFrom.clear(); // server honest again
    final fixed = await sender.reconcile(
      envelopes: first,
      required: {bob, bobWeb},
      identityIds: [bob],
      payload: payload,
    );
    expect(fixed.keys, unorderedEquals([bob, bobWeb]));
    expect(fixed[bob], first[bob]);
  });

  test('stale: a device the server no longer has is dropped, others resent as is',
      () async {
    await serveBobList(1, [bobWeb]);
    final first = await sendThenReconcile([bob], {bob, bobWeb});
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

  test('stale: a newly listed device gets an envelope after the list verifies',
      () async {
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

  test('stale: a device the server demands but nobody signed is refused',
      () async {
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

  test('stale: our own sending device is never a target', () async {
    await serveBobList(1, []);
    final first = await sender.encrypt([bob], payload);
    expect(
      sender.reconcile(
        envelopes: first,
        required: {bob, me},
        identityIds: [bob],
        payload: payload,
      ),
      throwsA(
        isA<DeviceListException>().having(
          (e) => e.reason,
          'reason',
          'server_requires_unverified_device',
        ),
      ),
    );
  });

  test('stale: a verified device of an identity outside the send is refused',
      () async {
    await serveBobList(1, [bobWeb]);
    final first = await sendThenReconcile([bob, carol], {bob, bobWeb, carol});
    expect(
      sender.reconcile(
        envelopes: {carol: first[carol]!},
        required: {carol, bobWeb},
        identityIds: [carol],
        payload: payload,
      ),
      throwsA(
        isA<DeviceListException>().having(
          (e) => e.reason,
          'reason',
          'server_requires_unverified_device',
        ),
      ),
    );
  });
}
