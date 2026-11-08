import 'dart:async';
import 'dart:convert';
import 'package:calltype/features/chat/attachment.dart';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype/features/chat/message_inbox_service.dart';
import '../../helpers/test_device.dart';

class GroupApi extends ApiClient {
  GroupApi() : super(baseUrl: 'http://unused');
  List<String> members = ['alice', 'bob'];
  @override
  Future<List<String>> getGroupMembers(String groupId) async => members;
}

void main() {
  late TestDevice alice;
  late TestDevice bob;
  late StreamController<Map<String, dynamic>> transport;
  late MessageInboxService inbox;
  late GroupApi groupApi;
  late List<String> acknowledgements;
  var nextId = 0;
  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    alice = await TestDevice.create('alice');
    bob = await TestDevice.create('bob');
    transport = StreamController<Map<String, dynamic>>();
    acknowledgements = [];
    groupApi = GroupApi();
    inbox = MessageInboxService(
      database: bob.db,
      sessionManager: bob.sessions,
      directory: () => bob.directory,
      incomingMessages: transport.stream,
      apiClient: groupApi,
      acknowledge: (sender, id) async {
        final row = await (bob.db.select(
          bob.db.messages,
        )..where((m) => m.id.equals(id))).getSingle();
        expect(row.senderId, sender);
        acknowledgements.add(id);
      },
    );
    inbox.start();
    await alice.sessions.initiateSession(bob.id, await bob.keyBundle());
  });
  tearDown(() async {
    await inbox.dispose();
    await transport.close();
    await alice.close();
    await bob.close();
  });
  Future<Map<String, dynamic>> payload(
    String body, {
    String? groupId,
    String type = 'text',
  }) async {
    final id = 'message-${nextId++}';
    final envelope = await alice.sessions.encryptMessage(
      bob.id,
      jsonEncode({
        'v': 1,
        'id': id,
        'body': body,
        'groupId': groupId,
        'type': type,
      }),
    );
    return {
      'messageId': id,
      'senderId': alice.id,
      'encryptedBody': base64Encode(utf8.encode(envelope)),
      'groupId': groupId,
    };
  }

  Future<void> settle() async =>
      MessageProcessingQueue.forDatabase(bob.db).run(() async {});
  Future<void> add(Map<String, dynamic> data) async {
    transport.add(data);
    await Future<void>.delayed(Duration.zero);
    await settle();
  }

  test('persists and acknowledges direct message with closed chat', () async {
    await add(await payload('hello'));
    final rows = await bob.db.select(bob.db.messages).get();
    expect(rows.single.body, 'hello');
    expect(rows.single.conversationId, alice.id);
    expect(rows.single.status, 'delivered');
    expect(acknowledgements, [rows.single.id]);
  });
  test(
    'redelivery retains sender UUID and increments unread only once',
    () async {
      final data = await payload('once');
      await add(data);
      await add(data);
      final rows = await bob.db.select(bob.db.messages).get();
      expect(rows, hasLength(1));
      expect(rows.single.id, data['messageId']);
      expect(
        (await bob.db.select(bob.db.conversations).get()).single.unreadCount,
        1,
      );
      expect(acknowledgements, [data['messageId'], data['messageId']]);
    },
  );
  test(
    'redelivery after a lost ack does not re-advance the ratchet',
    () async {
      // A replayed delivery must ack without touching the Double Ratchet —
      // otherwise a lost ack + retry would desync sender/receiver chains.
      // We prove this by comparing the raw serialized session state (not
      // just the displayed message) before and after the duplicate.
      final data = await payload('once');
      await add(data);
      final sessionBefore = await (bob.db.select(
        bob.db.signalSessions,
      )..where((s) => s.address.equals(alice.id))).getSingle();
      await add(data);
      final sessionAfter = await (bob.db.select(
        bob.db.signalSessions,
      )..where((s) => s.address.equals(alice.id))).getSingle();
      expect(sessionAfter.sessionData, sessionBefore.sessionData);
    },
  );
  test('concurrent deliveries serialize ratchet updates', () async {
    final data = await Future.wait([payload('one')]);
    final second = await payload('two');
    transport.add(data.single);
    transport.add(second);
    await Future<void>.delayed(Duration.zero);
    await settle();
    expect((await bob.db.select(bob.db.messages).get()).map((m) => m.body), [
      'one',
      'two',
    ]);
    expect(
      (await bob.db.select(bob.db.conversations).get()).single.unreadCount,
      2,
    );
  });
  test('group context survives encryption into group conversation', () async {
    await add(await payload('hi all', groupId: 'g1'));
    expect(
      (await bob.db.select(bob.db.messages).get()).single.conversationId,
      'g1',
    );
    expect(
      (await bob.db.select(bob.db.conversations).get()).single.type,
      'group',
    );
  });
  test(
    'authorized queued group message survives later membership removal',
    () async {
      final queued = await payload('before removal', groupId: 'g1');
      groupApi.members = ['bob'];
      await add(queued);
      expect(
        (await bob.db.select(bob.db.messages).get()).single.body,
        'before removal',
      );
      expect(acknowledgements, [queued['messageId']]);
    },
  );
  test('encrypted attachment bytes persist with file type', () async {
    final attachment = Attachment(
      name: 'sample.bin',
      bytes: Uint8List.fromList([0, 255, 42]),
    );
    await add(await payload(attachment.encode(), type: 'file'));
    final message = await bob.db.select(bob.db.messages).getSingle();
    expect(message.type, 'file');
    expect(Attachment.decode(message.body!).bytes, attachment.bytes);
    expect(acknowledgements, [message.id]);
  });
  test('tampered group context is rejected without acknowledgment', () async {
    final data = await payload('private');
    data['groupId'] = 'g1';
    await add(data);
    expect(await bob.db.select(bob.db.messages).get(), isEmpty);
    expect(acknowledgements, isEmpty);
  });
  test(
    'corrupt ciphertext is not falsely delivered and next message survives',
    () async {
      await add({
        'messageId': 'bad',
        'senderId': alice.id,
        'encryptedBody': base64Encode(utf8.encode('bad')),
      });
      expect(await bob.db.select(bob.db.messages).get(), isEmpty);
      expect(acknowledgements, isEmpty);
      await add(await payload('still alive'));
      expect(
        (await bob.db.select(bob.db.messages).get()).single.body,
        'still alive',
      );
    },
  );
}
