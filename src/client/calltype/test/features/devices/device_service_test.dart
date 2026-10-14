import 'package:calltype/core/storage/database.dart';
import 'package:calltype/features/devices/device_service.dart';
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

  Future<List<Message>> deviceLines(TestDevice device) =>
      (device.db.select(device.db.messages)
            ..where((m) => m.type.equals('device-change')))
          .get();

  test('a verified list makes this device a companion of the primary', () async {
    final service = await linkedWeb();
    expect(service.isCompanion, isTrue);
    expect(service.directory.selfIdentityId, phoneId);
    expect(service.status, CompanionStatus.ok);
  });

  test('a verified removal wipes the companion, which is a plain device again', () async {
    final service = await linkedWeb();
    await addChat(web, bobId);
    await server.link(phone, [], version: 2);
    await service.checkOwnList();
    await until(() => service.status == CompanionStatus.removed);
    expect(await web.db.select(web.db.messages).get(), isEmpty);
    expect(await web.db.select(web.db.conversations).get(), isEmpty);
    expect(service.isCompanion, isFalse);
    expect(service.directory.selfIdentityId, webId);
  });

  test('a list that does not verify, or no list at all, deletes nothing', () async {
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
  });

  test('a contact who links a device gets one line in the chat; a first fetch and our own list do not', () async {
    final service = await server.deviceServiceFor(phone);
    await addChat(phone, bobId);
    // First list ever stored for Bob, already with a companion: no line.
    await server.link(bob, [bobWeb], version: 1);
    await service.directory.refresh(bobId, ensurePinned: server.pinFor(phone));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await deviceLines(phone), isEmpty);
    // Bob removes and re-adds the device: two verified versions apart, so
    // each change is a line.
    await server.link(bob, [], version: 2);
    await service.directory.refresh(bobId, ensurePinned: server.pinFor(phone));
    await until(() async => (await deviceLines(phone)).length == 1);
    expect((await deviceLines(phone)).single.body, 'removed');
    await server.link(bob, [bobWeb], version: 3);
    await service.directory.refresh(bobWebId, ensurePinned: server.pinFor(phone));
    await until(() async => (await deviceLines(phone)).length == 2);
    final line = (await deviceLines(phone)).firstWhere((m) => m.body == 'added');
    expect(line.conversationId, bobId);
    expect(line.senderId, bobId);

    await server.link(phone, [web], version: 1);
    await service.checkOwnList(phoneId);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await deviceLines(phone), hasLength(2));
  });

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

  test('a version conflict reloads the newer list and signs on top of it', () async {
    await server.link(phone, [web], version: 1);
    final service = await server.deviceServiceFor(phone);
    await service.checkOwnList(phoneId);
    // An edit whose result this device never stored is already at version 3.
    await server.link(phone, [web], version: 3);

    await service.removeCompanions({webId});

    expect(server.lists[phoneId]!['version'], 4);
    expect(await service.companions(), isEmpty);
  });

  test('a stale answer without one of our companions re-signs without it', () async {
    await server.link(phone, [web], version: 1);
    final service = await server.deviceServiceFor(phone);
    await service.checkOwnList(phoneId);

    await service.dropVanishedCompanions({bobId});
    expect(await service.companions(), isEmpty);
    // Nothing vanished any more: no further version.
    await service.dropVanishedCompanions({bobId});
    expect(server.lists[phoneId]!['version'], 2);
  });

  test('a list-changed hint for a foreign identity is ignored', () async {
    await server.deviceServiceFor(phone);
    await server.link(bob, [bobWeb], version: 1);
    server.hubs[phoneId]!.listChanged.add({'primaryDeviceId': bobId, 'version': 1});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(server.deviceListRequests, isEmpty);
  });
}
