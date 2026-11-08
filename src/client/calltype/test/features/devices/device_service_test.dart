import 'package:calltype_core/storage/database.dart';
import 'package:calltype/features/devices/device_service.dart';
import 'package:calltype_core/crypto/device_list.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_multi_device_server.dart';
import '../../helpers/test_device.dart';

const phoneId = 'a0000000-0000-4000-8000-000000000001';
const webId = 'a0000000-0000-4000-8000-000000000002';
const bobId = 'b0000000-0000-4000-8000-000000000001';
const bobWebId = 'b0000000-0000-4000-8000-000000000002';

void main() {
  late FakeMultiDeviceServer server;
  late TestDevice phone;
  late TestDevice web;
  late TestDevice bob;
  late TestDevice bobWeb;

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    server = FakeMultiDeviceServer();
    phone = await TestDevice.create(phoneId);
    web = await TestDevice.create(webId);
    bob = await TestDevice.create(bobId);
    bobWeb = await TestDevice.create(bobWebId);
    for (final d in [phone, web, bob, bobWeb]) {
      server.add(d);
    }
  });

  tearDown(() async {
    await server.close();
    for (final d in [phone, web, bob, bobWeb]) {
      await d.close();
    }
  });

  /// The web device after the phone linked it and the hint arrived.
  Future<DeviceService> linkedWeb() async {
    await server.link(phone, [web], version: 1);
    final service = await server.deviceServiceFor(web);
    service.expectLink(phoneId);
    await service.checkOwnList(phoneId);
    return service;
  }

  Future<void> addChat(TestDevice device, String peer) async {
    await device.db
        .into(device.db.conversations)
        .insert(ConversationsCompanion.insert(id: peer, type: 'direct'));
    await device.db
        .into(device.db.messages)
        .insert(
          MessagesCompanion.insert(
            id: 'hello-$peer',
            conversationId: peer,
            senderId: peer,
            body: const Value('hello'),
            createdAt: DateTime.now(),
          ),
        );
  }

  Future<List<Message>> deviceLines(TestDevice device) => (device.db.select(
    device.db.messages,
  )..where((m) => m.type.equals('device-change'))).get();

  test(
    'a verified list makes this device a companion of the primary',
    () async {
      final service = await linkedWeb();
      expect(service.isCompanion, isTrue);
      expect(service.directory.selfIdentityId, phoneId);
      expect(service.status, CompanionStatus.ok);
    },
  );

  test(
    'a verified removal wipes the companion, which is a plain device again',
    () async {
      final service = await linkedWeb();
      await addChat(web, bobId);
      await server.link(phone, [], version: 2);
      await service.checkOwnList();
      await until(() => service.status == CompanionStatus.removed);
      expect(await web.db.select(web.db.messages).get(), isEmpty);
      expect(await web.db.select(web.db.conversations).get(), isEmpty);
      expect(service.isCompanion, isFalse);
      expect(service.directory.selfIdentityId, webId);
    },
  );

  test(
    'a list that does not verify, or no list at all, deletes nothing',
    () async {
      final service = await linkedWeb();
      await addChat(web, bobId);
      // The server serves a "removal" that the phone did not sign.
      server.lists[phoneId] = await server.signedList(bob, phoneId, 2, []);
      await service.checkOwnList();
      expect(service.status, CompanionStatus.cannotVerify);
      // The server pretends the list is gone.
      server.lists.remove(phoneId);
      server.members.remove(webId);
      await service.checkOwnList();
      expect(service.status, CompanionStatus.cannotVerify);
      expect(await web.db.select(web.db.messages).get(), hasLength(1));
      expect(service.isCompanion, isTrue);
    },
  );

  test(
    'a contact who links a device gets a line in the chat, even on the first list; our own list does not',
    () async {
      final service = await server.deviceServiceFor(phone);
      await addChat(phone, bobId);
      // First list ever stored for Bob, already with a companion: the first
      // new reader of an existing conversation is never silent.
      await server.link(bob, [bobWeb], version: 1);
      await service.directory.refresh(
        bobId,
        ensurePinned: server.pinFor(phone),
      );
      await until(() async => (await deviceLines(phone)).length == 1);
      expect((await deviceLines(phone)).single.body, 'added');
      // Bob removes and re-adds the device: two verified versions apart, so
      // each change is a line.
      await server.link(bob, [], version: 2);
      await service.directory.refresh(
        bobId,
        ensurePinned: server.pinFor(phone),
      );
      await until(() async => (await deviceLines(phone)).length == 2);
      expect((await deviceLines(phone)).last.body, 'removed');
      await server.link(bob, [bobWeb], version: 3);
      await service.directory.refresh(
        bobWebId,
        ensurePinned: server.pinFor(phone),
      );
      await until(() async => (await deviceLines(phone)).length == 3);
      final line = (await deviceLines(
        phone,
      )).firstWhere((m) => m.body == 'added');
      expect(line.conversationId, bobId);
      expect(line.senderId, bobId);

      await server.link(phone, [web], version: 1);
      await service.checkOwnList(phoneId);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await deviceLines(phone), hasLength(3));
    },
  );

  test('removing a companion signs the next version and stores it', () async {
    await server.link(phone, [web], version: 1);
    final service = await server.deviceServiceFor(phone);
    await service.checkOwnList(phoneId);
    expect((await service.companions()).map((d) => d.deviceId), [webId]);

    await service.removeCompanions({webId});

    expect(server.lists[phoneId]!['version'], 2);
    expect(await service.companions(), isEmpty);
    expect(await service.directory.devicesOf(phoneId), [phoneId]);
  });

  test(
    'a version conflict reloads the newer list and signs on top of it',
    () async {
      await server.link(phone, [web], version: 1);
      final service = await server.deviceServiceFor(phone);
      await service.checkOwnList(phoneId);
      // An edit whose result this device never stored is already at version 3.
      await server.link(phone, [web], version: 3);

      await service.removeCompanions({webId});

      expect(server.lists[phoneId]!['version'], 4);
      expect(await service.companions(), isEmpty);
    },
  );

  group('vanished companions', () {
    Future<DeviceService> phoneWithWeb() async {
      await server.link(phone, [web], version: 1);
      final service = await server.deviceServiceFor(phone);
      await service.checkOwnList(phoneId);
      return service;
    }

    test('are recorded, persisted and ignored when not ours', () async {
      final service = await phoneWithWeb();
      await service.reportVanishedCompanions({bobId, webId});
      expect(service.vanishedCompanions, {webId});
      // Nothing was re-signed on the server's word alone.
      expect(server.lists[phoneId]!['version'], 1);

      final reopened = DeviceService(
        database: phone.db,
        apiClient: FakeDeviceApi(server),
        keyManager: phone.keys,
        sessionManager: phone.sessions,
        signalRClient: server.hubs[phoneId]!,
      );
      await reopened.open(phoneId);
      expect(reopened.vanishedCompanions, {webId});
      reopened.dispose();
    });

    test('confirming signs the list without them', () async {
      final service = await phoneWithWeb();
      await service.reportVanishedCompanions({webId});
      await service.confirmRemoveVanished();
      expect(server.lists[phoneId]!['version'], 2);
      expect(await service.companions(), isEmpty);
      expect(service.vanishedCompanions, isEmpty);
    });

    test('dismissing keeps the list and clears the prompt', () async {
      final service = await phoneWithWeb();
      await service.reportVanishedCompanions({webId});
      await service.dismissVanished();
      expect(service.vanishedCompanions, isEmpty);
      expect(server.lists[phoneId]!['version'], 1);
      expect((await service.companions()).map((d) => d.deviceId), [webId]);
    });

    test('dismissing with ids keeps the other rows pending', () async {
      final extra = await TestDevice.create('a0000000-0000-4000-8000-000000000003');
      addTearDown(extra.close);
      server.add(extra);
      await server.link(phone, [web, extra], version: 1);
      final service = await server.deviceServiceFor(phone);
      await service.checkOwnList(phoneId);
      await service.reportVanishedCompanions([webId, extra.id]);

      await service.dismissVanished(ids: [webId]);

      expect(service.vanishedCompanions, {extra.id});
    });

    test('a normal removal clears the pending entry', () async {
      final service = await phoneWithWeb();
      await service.reportVanishedCompanions({webId});
      await service.removeCompanions({webId});
      await until(() => service.vanishedCompanions.isEmpty);
    });
  });

  test('a list-changed hint for a foreign identity is ignored', () async {
    await server.deviceServiceFor(phone);
    await server.link(bob, [bobWeb], version: 1);
    server.hubs[phoneId]!.listChanged.add({
      'primaryDeviceId': bobId,
      'version': 1,
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(server.deviceListRequests, isEmpty);
  });

  test(
    'after a wipe an old list cannot re-link the device or wipe it again',
    () async {
      final service = await linkedWeb();
      final v1 = Map<String, dynamic>.of(server.lists[phoneId]!);
      await server.link(phone, [], version: 2);
      final v2 = Map<String, dynamic>.of(server.lists[phoneId]!);
      await service.checkOwnList();
      await until(() => service.status == CompanionStatus.removed);
      // Data the user creates after the wipe.
      await addChat(web, bobId);

      // A hostile server replays the old list that still contains this device.
      server.lists[phoneId] = v1;
      server.members[webId] = phoneId;
      await service.checkOwnList(phoneId);
      expect(service.isCompanion, isFalse);
      expect(service.directory.selfIdentityId, webId);

      // ... and then the removal again: nothing new, so no second wipe.
      server.lists[phoneId] = v2;
      server.members.remove(webId);
      await service.checkOwnList(phoneId);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await web.db.select(web.db.messages).get(), hasLength(1));
    },
  );

  test('a wipe that never ran is completed when the service opens', () async {
    // State after a crash: the removal (v2) is stored, the marker is still
    // there, the chats were not deleted.
    final removal = await server.signedList(phone, phoneId, 2, []);
    await web.db
        .into(web.db.knownDeviceLists)
        .insert(
          KnownDeviceListsCompanion.insert(
            primaryDeviceId: phoneId,
            version: 2,
            payload: removal['payload'] as String,
            signature: removal['signature'] as String,
          ),
        );
    await web.db
        .into(web.db.backupState)
        .insert(
          BackupStateCompanion.insert(key: companionOfKey, value: phoneId),
        );
    await addChat(web, bobId);

    await server.deviceServiceFor(web);

    expect(await web.db.select(web.db.messages).get(), isEmpty);
    expect(await web.db.select(web.db.backupState).get(), isEmpty);
  });

  test('a device waiting to be linked finds the link without a hint', () async {
    await server.link(phone, [web], version: 1);
    final service = await server.deviceServiceFor(web);
    service.expectLink(phoneId);
    await service.checkOwnList();
    expect(service.isCompanion, isTrue);
  });

  test(
    'the primary signs only entries whose consent verifies, and the server needs the LinkConsent',
    () async {
      final service = await server.deviceServiceFor(phone);
      Future<DeviceListEntry> entryFor(
        TestDevice d,
        String consentPrimary,
      ) async => DeviceListEntry(
        deviceId: d.id,
        identityKey: await d.keys.getPublicIdentityKey(),
        signingKey: (await d.keys.getSignedIdentityBundle())['signingKey']!,
        consentSig: await signDeviceLinkConsent(
          companionSigningKey: await d.keys.getSigningKeyPair(),
          primaryDeviceId: consentPrimary,
          companionDeviceId: d.id,
        ),
      );

      // Consent given for somebody else's list: refused before any PUT.
      await expectLater(
        service.addCompanion(await entryFor(web, bobId)),
        throwsA(isA<DeviceListException>()),
      );
      expect(server.lists, isEmpty);

      // Valid consent, but the device never said LinkConsent to the server.
      final entry = await entryFor(web, phoneId);
      await expectLater(
        service.addCompanion(entry),
        throwsA(isA<DioException>()),
      );
      expect(server.lists, isEmpty);

      server.recordConsent(webId, phoneId);
      await service.addCompanion(entry);
      expect((await service.companions()).map((d) => d.deviceId), [webId]);
    },
  );
}
