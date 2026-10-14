import 'package:calltype_core/crypto/device_list.dart';
import 'package:calltype_core/devices/device_directory.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:test/test.dart';

import '../helpers/test_device.dart';

const me = '10000000-0000-4000-8000-000000000001';
const bob = '20000000-0000-4000-8000-000000000002';
const bobWeb = '20000000-0000-4000-8000-000000000003';
const rogue = '90000000-0000-4000-8000-000000000009';
const mallory = '80000000-0000-4000-8000-000000000008';
const carol = '30000000-0000-4000-8000-000000000004';

class ListApi extends ApiClient {
  ListApi() : super(baseUrl: 'http://unused');
  final served = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, dynamic>?> getDeviceList(String deviceId) async =>
      served[deviceId];
}

void main() {
  late TestDevice self;
  late TestDevice bobPhone;
  late TestDevice bobCompanion;
  late ListApi api;
  late DeviceDirectory directory;

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    self = await TestDevice.create(me);
    bobPhone = await TestDevice.create(bob);
    bobCompanion = await TestDevice.create(bobWeb);
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
  });

  tearDown(() async {
    await self.close();
    await bobPhone.close();
    await bobCompanion.close();
  });

  /// Bob's list as the server would serve it, signed by [signer].
  Future<Map<String, dynamic>> bobList(
    int version,
    List<TestDevice> companions, {
    TestDevice? signer,
  }) async {
    final signed = await signDeviceList(
      primarySigningKey: await (signer ?? bobPhone).keys.getSigningKeyPair(),
      list: DeviceList(
        primaryDeviceId: bob,
        version: version,
        devices: [
          for (final c in companions)
            DeviceListEntry(
              deviceId: c.id,
              identityKey: await c.keys.getPublicIdentityKey(),
              signingKey: (await c.keys.getSignedIdentityBundle())['signingKey']!,
              consentSig: await signDeviceLinkConsent(
                companionSigningKey: await c.keys.getSigningKeyPair(),
                primaryDeviceId: bob,
                companionDeviceId: c.id,
              ),
            ),
        ],
      ),
    );
    return {
      'primaryDeviceId': bob,
      'version': version,
      'payload': signed.payload,
      'signature': signed.signature,
    };
  }

  /// A list signed by [signer] for [primaryId], naming [entries] (device id
  /// and the device whose keys and consent go into the entry).
  Future<Map<String, dynamic>> listBy(
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
          for (final (id, k) in entries)
            DeviceListEntry(
              deviceId: id,
              identityKey: await k.keys.getPublicIdentityKey(),
              signingKey: (await k.keys.getSignedIdentityBundle())['signingKey']!,
              consentSig: await signDeviceLinkConsent(
                companionSigningKey: await k.keys.getSigningKeyPair(),
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

  /// Pins [peer] (a device the test controls) the way a first message would.
  Future<void> Function(String) pinOf(TestDevice peer) =>
      (id) async => self.sessions.initiateSession(id, await peer.keyBundle());

  Matcher refusedWith(String reason) => throwsA(
    isA<DeviceListException>().having((e) => e.reason, 'reason', reason),
  );

  /// What a real client does before it can verify Bob's list: start a session
  /// with Bob's primary, which pins his identity and signing key.
  Future<void> pinBob(String primary) async {
    if (!await self.sessions.hasSession(primary)) {
      await self.sessions.initiateSession(primary, await bobPhone.keyBundle());
    }
  }

  test('a verified list maps companions to the identity', () async {
    api.served[bob] = await bobList(1, [bobCompanion]);
    final change = await directory.refresh(bob, ensurePinned: pinBob);
    expect(change!.added, {bobWeb});
    expect(await directory.identityOf(bobWeb), bob);
    expect(await directory.devicesOf(bob), [bob, bobWeb]);
    expect(await directory.fanoutTargets([bob]), unorderedEquals([bob, bobWeb]));
  });

  test('a device the server injects without a valid signature is ignored', () async {
    api.served[bob] = await bobList(1, [bobCompanion]);
    await directory.refresh(bob, ensurePinned: pinBob);
    // The "server" now serves a list signed by somebody else that adds a device.
    final attacker = await TestDevice.create(rogue);
    addTearDown(attacker.close);
    api.served[bob] = await bobList(2, [bobCompanion, attacker], signer: attacker);
    await expectLater(
      directory.refresh(bob, ensurePinned: pinBob),
      throwsA(isA<DeviceListException>()),
    );
    expect(await directory.devicesOf(bob), [bob, bobWeb]);
  });

  test('a replayed older list cannot bring a removed device back', () async {
    final v1 = await bobList(1, [bobCompanion]);
    api.served[bob] = v1;
    await directory.refresh(bob, ensurePinned: pinBob);
    api.served[bob] = await bobList(2, []);
    final change = await directory.refresh(bob, ensurePinned: pinBob);
    expect(change!.removed, {bobWeb});
    api.served[bob] = v1;
    await expectLater(
      directory.refresh(bob, ensurePinned: pinBob),
      throwsA(isA<DeviceListException>()),
    );
    expect(await directory.devicesOf(bob), [bob]);
  });

  test('no list, or the same list again, changes nothing', () async {
    expect(await directory.refresh(bob, ensurePinned: pinBob), isNull);
    api.served[bob] = await bobList(1, [bobCompanion]);
    await directory.refresh(bob, ensurePinned: pinBob);
    expect(await directory.refresh(bob, ensurePinned: pinBob), isNull);
    // "The list is gone" from the server must not erase what was verified.
    api.served.remove(bob);
    expect(await directory.refresh(bob, ensurePinned: pinBob), isNull);
    expect(await directory.devicesOf(bob), [bob, bobWeb]);
  });

  test('inbound routing: peer companion, own device, unrelated device', () async {
    api.served[bob] = await bobList(1, [bobCompanion]);
    await directory.refresh(bob, ensurePinned: pinBob);

    final fromBobWeb = await directory.routeInbound(senderDeviceId: bobWeb);
    expect(fromBobWeb.conversationId, bob);
    expect(fromBobWeb.senderIdentityId, bob);
    expect(fromBobWeb.own, isFalse);

    final stranger = await directory.routeInbound(senderDeviceId: rogue);
    expect(stranger.conversationId, rogue);

    final group = await directory.routeInbound(senderDeviceId: bobWeb, groupId: 'g1');
    expect(group.conversationId, 'g1');
    expect(group.senderIdentityId, bob);
  });

  test('a copy from our own device goes to the conversation named in `to`', () async {
    // This device becomes a companion of `bob`'s identity for the test:
    // simplest way to have a sibling without a third key set.
    await self.db.into(self.db.knownDeviceListMembers).insert(
      KnownDeviceListMembersCompanion.insert(deviceId: me, primaryDeviceId: bob),
    );
    await directory.load();
    expect(directory.selfIdentityId, bob);
    expect(directory.isCompanion, isTrue);

    final copy = await directory.routeInbound(senderDeviceId: bob, to: 'carol');
    expect(copy.own, isTrue);
    expect(copy.conversationId, 'carol');
    expect(
      directory.routeInbound(senderDeviceId: bob),
      throwsA(isA<DeviceListException>()),
    );
  });

  test('a companion whose pinned keys differ from the signed entry is refused', () async {
    api.served[bob] = await bobList(1, [bobCompanion]);
    await directory.refresh(bob, ensurePinned: pinBob);
    // Nothing pinned: fail closed. Consent only proves the key written in the
    // entry agreed; the pinned keys are what tie the entry to the real device.
    await expectLater(
      directory.assertListedKeys(bobWeb),
      throwsA(isA<DeviceListException>()),
    );
    await self.db.into(self.db.backupState).insert(
      BackupStateCompanion.insert(key: 'peer_identity:$bobWeb', value: 'x|y'),
    );
    expect(
      directory.assertListedKeys(bobWeb),
      throwsA(isA<DeviceListException>()),
    );
  });

  group('hostile lists', () {
    late TestDevice mal;
    setUp(() async => mal = await TestDevice.create(mallory));
    tearDown(() => mal.close());

    test('a list naming us with keys that are not ours is refused', () async {
      api.served[bob] = await listBy(mal, mallory, 1, [(me, mal)]);
      await expectLater(
        directory.refresh(bob, ensurePinned: pinOf(mal)),
        refusedWith('self_not_consented'),
      );
      expect(directory.selfIdentityId, me);
      expect(await directory.fanoutTargets([carol]), [carol]);
    });

    test('a validly signed list that does not concern the asked device', () async {
      api.served[bob] = await listBy(mal, mallory, 1, [(carol, bobCompanion)]);
      await expectLater(
        directory.refresh(bob, ensurePinned: pinOf(mal)),
        refusedWith('unrelated_list'),
      );
      expect(await directory.devicesOf(mallory), [mallory]);
    });

    test('a list cannot claim a device whose keys we already pinned', () async {
      // Bob wrote first: his real keys are pinned, no list or contact exists.
      await pinBob(bob);
      api.served[bob] = await listBy(mal, mallory, 1, [(bob, mal)]);
      await expectLater(
        directory.refresh(bob, ensurePinned: pinOf(mal)),
        refusedWith('listed_keys_mismatch'),
      );
      expect(await directory.identityOf(bob), bob);
      expect(await directory.devicesOf(mallory), [mallory]);

      // The refusal wrote nothing, so Bob's real list still goes through.
      api.served[bob] = await bobList(1, [bobCompanion]);
      await directory.refresh(bob, ensurePinned: pinBob);
      expect(await directory.identityOf(bobWeb), bob);
    });

    test('another identity cannot take over a device already mapped', () async {
      api.served[bob] = await bobList(1, [bobCompanion]);
      await directory.refresh(bob, ensurePinned: pinBob);
      api.served[bobWeb] = await listBy(mal, mallory, 1, [(bobWeb, bobCompanion)]);
      await expectLater(
        directory.refresh(bobWeb, ensurePinned: pinOf(mal)),
        refusedWith('device_claimed_by_other_identity'),
      );
      expect(await directory.identityOf(bobWeb), bob);
      expect(await directory.devicesOf(mallory), [mallory]);
    });

    test('a known primary or contact cannot be listed as a companion', () async {
      api.served[bob] = await bobList(1, [bobCompanion]);
      await directory.refresh(bob, ensurePinned: pinBob);
      api.served[bob] = await listBy(mal, mallory, 1, [(bob, bobPhone)]);
      await expectLater(
        directory.refresh(bob, ensurePinned: pinOf(mal)),
        refusedWith('device_claimed_by_other_identity'),
      );
      expect(await directory.identityOf(bob), bob);

      // A contact without a stored list is a known primary too.
      await self.db.into(self.db.contacts).insert(
        ContactsCompanion.insert(
          deviceId: carol,
          userHandle: 'CT-AAAA-BBBB',
          identityKey: Uint8List(32),
          addedAt: DateTime.now(),
        ),
      );
      api.served[carol] = await listBy(mal, mallory, 1, [(carol, bobCompanion)]);
      await expectLater(
        directory.refresh(carol, ensurePinned: pinOf(mal)),
        refusedWith('device_claimed_by_other_identity'),
      );
      expect(await directory.identityOf(carol), carol);
    });
  });

  test('Bob legitimately links this device: accepted', () async {
    api.served[me] = await listBy(bobPhone, bob, 1, [(me, self)]);
    final change = await directory.refresh(me, ensurePinned: pinBob);
    expect(change!.added, {me});
    expect(directory.selfIdentityId, bob);
    expect(directory.isCompanion, isTrue);
  });

  test('concurrent refreshes end on the highest version', () async {
    api.served[bob] = await bobList(1, [bobCompanion]);
    await directory.refresh(bob, ensurePinned: pinBob);
    final v2 = await bobList(2, [bobCompanion]);
    final v3 = await bobList(3, []);
    api.served[bob] = v2;
    final first = directory.refresh(bob, ensurePinned: pinBob);
    api.served[bob] = v3;
    final second = directory.refresh(bob, ensurePinned: pinBob);
    await Future.wait([first, second]);
    final stored = await self.db.select(self.db.knownDeviceLists).getSingle();
    expect(stored.version, 3);
    expect(await directory.devicesOf(bob), [bob]);
  });

  test('an upper-case selfDeviceId still works', () async {
    final upper = DeviceDirectory(
      database: self.db,
      apiClient: api,
      selfDeviceId: me.toUpperCase(),
      selfSigningKey: () async =>
          (await self.keys.getSignedIdentityBundle())['signingKey']!,
      selfIdentityKey: self.keys.getPublicIdentityKey,
    );
    await upper.load();
    expect(upper.selfDeviceId, me);
    expect(upper.selfIdentityId, me);
    api.served[bob] = await listBy(bobPhone, bob, 1, [(me, self)]);
    await upper.refresh(bob.toUpperCase(), ensurePinned: pinBob);
    expect(upper.selfIdentityId, bob);
  });

  test('assertListedKeys on an unknown listed device is a clean refusal', () async {
    await self.db.into(self.db.knownDeviceListMembers).insert(
      KnownDeviceListMembersCompanion.insert(deviceId: bobWeb, primaryDeviceId: bob),
    );
    await self.db.into(self.db.backupState).insert(
      BackupStateCompanion.insert(key: 'peer_identity:$bobWeb', value: 'x|y'),
    );
    await expectLater(
      directory.assertListedKeys(bobWeb),
      refusedWith('listed_device_unknown'),
    );
  });
}
