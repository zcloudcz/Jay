import 'dart:async';
import 'dart:convert';

import 'package:calltype/features/chat/message_inbox_service.dart';
import 'package:calltype_core/devices/device_directory.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_multi_device_server.dart';
import '../../helpers/test_device.dart';

const aPhoneId = 'a0000000-0000-4000-8000-000000000001';
const aWebId = 'a0000000-0000-4000-8000-000000000002';
const bobId = 'b0000000-0000-4000-8000-000000000001';
const malloryId = 'c0000000-0000-4000-8000-000000000001';

void main() {
  late FakeMultiDeviceServer server;
  late TestDevice aPhone;
  late TestDevice aWeb;
  late TestDevice bob;
  late TestDevice mallory;
  late StreamController<Map<String, dynamic>> wire;
  late List<(String, String)> acks;
  var next = 0;

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    server = FakeMultiDeviceServer();
    aPhone = await TestDevice.create(aPhoneId);
    aWeb = await TestDevice.create(aWebId);
    bob = await TestDevice.create(bobId);
    mallory = await TestDevice.create(malloryId);
    for (final d in [aPhone, aWeb, bob, mallory]) {
      server.add(d);
    }
    wire = StreamController<Map<String, dynamic>>();
    acks = [];
  });

  tearDown(() async {
    unawaited(wire.close());
    await server.close();
    for (final d in [aPhone, aWeb, bob, mallory]) {
      await d.close();
    }
  });

  /// Starts [receiver]'s inbox on [wire], with a directory backed by the
  /// fake server.
  Future<DeviceDirectory> inboxOf(TestDevice receiver) async {
    final directory = server.directoryFor(receiver);
    await directory.load();
    final inbox = MessageInboxService(
      database: receiver.db,
      sessionManager: receiver.sessions,
      incomingMessages: wire.stream,
      apiClient: FakeDeviceApi(server),
      directory: () => directory,
      acknowledge: (sender, id) async => acks.add((sender, id)),
    )..start();
    addTearDown(inbox.dispose);
    return directory;
  }

  /// [from] encrypts a direct text for [to] and the hub delivers it.
  Future<String> deliver(
    TestDevice from,
    TestDevice to,
    String body, {
    String? toConversation,
  }) async {
    if (!await from.sessions.hasSession(to.id)) {
      await from.sessions.initiateSession(to.id, await to.keyBundle());
    }
    final id = 'm-${next++}';
    final cipher = await from.sessions.encryptMessage(
      to.id,
      jsonEncode({
        'v': 1,
        'id': id,
        'body': body,
        'type': 'text',
        'groupId': null,
        'to': ?toConversation,
      }),
    );
    wire.add({
      'senderId': from.id,
      'messageId': id,
      'encryptedBody': base64Encode(utf8.encode(cipher)),
      'groupId': null,
    });
    await Future<void>.delayed(Duration.zero);
    await MessageProcessingQueue.forDatabase(to.db).run(() async {});
    return id;
  }

  test('a contact\'s companion lands in the contact\'s chat, under the contact\'s id', () async {
    await server.link(aPhone, [aWeb], version: 1);
    await inboxOf(bob);
    final id = await deliver(aWeb, bob, 'from the web');
    final row = await bob.db.select(bob.db.messages).getSingle();
    expect(row.conversationId, aPhoneId);
    expect(row.senderId, aPhoneId);
    expect(row.status, 'delivered');
    // Acknowledged with the TRANSPORT sender: the server queues per device.
    expect(acks, [(aWebId, id)]);
  });

  test('a copy from our own other device goes to `to`, as sent and not unread', () async {
    await server.link(aPhone, [aWeb], version: 1);
    final directory = await inboxOf(aPhone);
    await directory.refresh(aPhoneId, ensurePinned: (_) async {});
    await deliver(aWeb, aPhone, 'sent from the web', toConversation: bobId);
    final row = await aPhone.db.select(aPhone.db.messages).getSingle();
    expect(row.conversationId, bobId);
    expect(row.senderId, aPhoneId);
    expect(row.status, 'sent');
    expect(
      (await aPhone.db.select(aPhone.db.conversations).getSingle()).unreadCount,
      0,
    );
  });

  test('an own copy without `to` is refused and stays queued', () async {
    await server.link(aPhone, [aWeb], version: 1);
    final directory = await inboxOf(aPhone);
    await directory.refresh(aPhoneId, ensurePinned: (_) async {});
    await deliver(aWeb, aPhone, 'nowhere');
    expect(await aPhone.db.select(aPhone.db.messages).get(), isEmpty);
    expect(acks, isEmpty);
  });

  test('a device whose keys differ from its signed entry is dropped but acknowledged', () async {
    // A's list names A's web device with Mallory's keys (her consent included).
    server.store(await server.signedList(aPhone, aPhoneId, 1, [(aWebId, mallory)]));
    await inboxOf(bob);
    final id = await deliver(aWeb, bob, 'who am I');
    expect(await bob.db.select(bob.db.messages).get(), isEmpty);
    expect(acks, [(aWebId, id)]);
  });

  test('an unknown sender is looked up once, not once per message', () async {
    await inboxOf(bob);
    await deliver(mallory, bob, 'one');
    await deliver(mallory, bob, 'two');
    expect(server.deviceListRequests, [malloryId]);
    expect(await bob.db.select(bob.db.messages).get(), hasLength(2));
  });
}
