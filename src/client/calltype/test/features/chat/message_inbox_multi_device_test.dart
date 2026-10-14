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

  test('an own copy without `to` is dropped and acknowledged', () async {
    await server.link(aPhone, [aWeb], version: 1);
    final directory = await inboxOf(aPhone);
    await directory.refresh(aPhoneId, ensurePinned: (_) async {});
    final id = await deliver(aWeb, aPhone, 'nowhere');
    expect(await aPhone.db.select(aPhone.db.messages).get(), isEmpty);
    expect(acks, [(aWebId, id)]);
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

  /// Like [deliver] but for any payload type, and returns the wire event
  /// without pushing it, so a test can deliver the same event twice.
  Future<Map<String, dynamic>> wireEvent(
    TestDevice from,
    TestDevice to,
    String body, {
    String type = 'text',
    String? groupId,
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
        'type': type,
        'groupId': groupId,
      }),
    );
    return {
      'senderId': from.id,
      'messageId': id,
      'encryptedBody': base64Encode(utf8.encode(cipher)),
      'groupId': groupId,
    };
  }

  Future<void> push(Map<String, dynamic> event, TestDevice to) async {
    wire.add(event);
    await Future<void>.delayed(Duration.zero);
    await MessageProcessingQueue.forDatabase(to.db).run(() async {});
  }

  test('a transient lookup failure leaves the message queued, then it is filed under the contact', () async {
    await server.link(aPhone, [aWeb], version: 1);
    final flaky = _FlakyListApi(server);
    final directory = DeviceDirectory(
      database: bob.db,
      apiClient: flaky,
      selfDeviceId: bob.id,
      selfSigningKey: () async =>
          (await bob.keys.getSignedIdentityBundle())['signingKey']!,
      selfIdentityKey: bob.keys.getPublicIdentityKey,
    );
    final inbox = MessageInboxService(
      database: bob.db,
      sessionManager: bob.sessions,
      incomingMessages: wire.stream,
      apiClient: FakeDeviceApi(server),
      directory: () => directory,
      acknowledge: (sender, id) async => acks.add((sender, id)),
    )..start();
    addTearDown(inbox.dispose);
    final event = await wireEvent(aWeb, bob, 'hello');

    await push(event, bob);
    expect(await bob.db.select(bob.db.messages).get(), isEmpty);
    expect(acks, isEmpty);
    expect(await bob.sessions.hasSession(aWebId), isFalse);

    flaky.failing = false;
    await push(event, bob);
    final row = await bob.db.select(bob.db.messages).getSingle();
    expect(row.senderId, aPhoneId);
    expect(row.conversationId, aPhoneId);
    expect(acks, [(aWebId, event['messageId'])]);
  });

  test('a redelivery after the companion left the list is acknowledged without a write', () async {
    await server.link(aPhone, [aWeb], version: 1);
    final directory = await inboxOf(bob);
    final event = await wireEvent(aWeb, bob, 'before removal');
    await push(event, bob);
    expect(
      (await bob.db.select(bob.db.messages).getSingle()).senderId,
      aPhoneId,
    );
    // A's list v2 drops the web device; Bob learns about it.
    await server.link(aPhone, [], version: 2);
    await directory.refresh(aPhoneId, ensurePinned: (_) async {});
    acks.clear();
    await push(event, bob);
    expect(acks, [(aWebId, event['messageId'])]);
    final rows = await bob.db.select(bob.db.messages).get();
    expect(rows, hasLength(1));
    expect(rows.single.senderId, aPhoneId);
  });

  test('delete for everyone from the other device of a contact tombstones the message', () async {
    await server.link(aPhone, [aWeb], version: 1);
    await inboxOf(bob);
    final sent = await wireEvent(aPhone, bob, 'oops');
    await push(sent, bob);
    final del = await wireEvent(
      aWeb,
      bob,
      sent['messageId'] as String,
      type: 'delete',
    );
    await push(del, bob);
    final row = await bob.db.select(bob.db.messages).getSingle();
    expect(row.deleted, isTrue);
    expect(row.body, isNull);
  });

  test('a delete from another identity is ignored', () async {
    await server.link(aPhone, [aWeb], version: 1);
    await inboxOf(bob);
    final sent = await wireEvent(aPhone, bob, 'keep me');
    await push(sent, bob);
    final del = await wireEvent(
      mallory,
      bob,
      sent['messageId'] as String,
      type: 'delete',
    );
    await push(del, bob);
    final row = await bob.db.select(bob.db.messages).getSingle();
    expect(row.deleted, isFalse);
    expect(row.body, 'keep me');
    expect(acks.last, (malloryId, del['messageId']));
  });

  test('a group message from the companion of a member lands in the group under the identity', () async {
    await server.link(aPhone, [aWeb], version: 1);
    await inboxOf(bob);
    await push(await wireEvent(aWeb, bob, 'hi all', groupId: 'g1'), bob);
    final row = await bob.db.select(bob.db.messages).getSingle();
    expect(row.conversationId, 'g1');
    expect(row.senderId, aPhoneId);
  });
}

/// Fails every device-list lookup like a 5xx until [failing] is cleared.
class _FlakyListApi extends FakeDeviceApi {
  _FlakyListApi(super.server);
  bool failing = true;

  @override
  Future<Map<String, dynamic>?> getDeviceList(String deviceId) {
    if (failing) throw StateError('503');
    return super.getDeviceList(deviceId);
  }
}
