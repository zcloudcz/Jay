import 'dart:async';
import 'dart:convert';

import 'package:calltype/core/network/api_client.dart';
import 'package:calltype/core/network/signalr_client.dart';
import 'package:calltype/core/storage/database.dart';
import 'package:calltype/features/chat/chat_controller.dart';
import 'package:calltype/features/chat/message_inbox_service.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_device.dart';

/// Reply / forward / delete-for-everyone: receiving side (inbox) and sending
/// side (controller), against real in-memory databases and real ratchets.

/// getGroupBusinessInfo is an extension method (not overridable), so the fake
/// answers at the HTTP layer. [_infoMode]: 'none' = anonymous group,
/// 'business' = business group, 'broken' = a response the client cannot
/// parse (it throws, unlike a DioException which the client maps to "none").
String _infoMode = 'none';

Dio _infoDio() {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.resolve(
          Response(
            requestOptions: options,
            data: switch (_infoMode) {
              'business' => <String, dynamic>{
                'organizationId': 'org',
                'organizationName': 'Acme',
                'auditorDeviceId': 'aud',
              },
              'broken' => null,
              _ => <String, dynamic>{},
            },
          ),
        );
      },
    ),
  );
  return dio;
}

class _Api extends ApiClient {
  _Api(this.peers) : super(baseUrl: 'http://unused', dio: _infoDio());
  final List<TestDevice> peers;
  @override
  Future<List<String>> getGroupMembers(String id) async => [
    'alice',
    ...peers.map((p) => p.id),
  ];
  @override
  Future<Map<String, dynamic>> getKeyBundle(String id) =>
      peers.firstWhere((p) => p.id == id).keyBundle();
}

class _Transport extends SignalRClient {
  _Transport() : super(baseUrl: 'http://unused', deviceId: 'alice');
  bool fail = false;
  final sent = <Map<String, String>>[];
  @override
  Future<void> sendMessage(
    String recipientDeviceId,
    String encryptedBodyBase64, {
    String? messageId,
  }) async {
    sent.add({recipientDeviceId: encryptedBodyBase64});
    if (fail) throw StateError('offline');
  }

  @override
  Future<void> sendGroupMessage(
    String groupId,
    Map<String, String> encryptedPayloads, {
    String? messageId,
  }) async {
    sent.add(Map.of(encryptedPayloads));
    if (fail) throw StateError('offline');
  }
}

void main() {
  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    _infoMode = 'none';
  });

  group('inbox', () {
    late TestDevice alice;
    late TestDevice carol;
    late TestDevice bob; // the receiver under test
    late StreamController<Map<String, dynamic>> transport;
    late MessageInboxService inbox;
    late List<String> acks;
    late List<Object> errors;
    var nextId = 0;

    setUp(() async {
      alice = await TestDevice.create('alice');
      carol = await TestDevice.create('carol');
      bob = await TestDevice.create('bob');
      transport = StreamController<Map<String, dynamic>>();
      acks = [];
      errors = [];
      inbox = MessageInboxService(
        database: bob.db,
        sessionManager: bob.sessions,
        incomingMessages: transport.stream,
        acknowledge: (sender, id) async => acks.add(id),
      );
      inbox.errors.listen(errors.add);
      inbox.start();
      await alice.sessions.initiateSession(bob.id, await bob.keyBundle());
      await carol.sessions.initiateSession(bob.id, await bob.keyBundle());
    });
    tearDown(() async {
      await inbox.dispose();
      await transport.close();
      await alice.close();
      await carol.close();
      await bob.close();
    });

    Future<Map<String, dynamic>> deliver(
      TestDevice from,
      Map<String, dynamic> fields,
    ) async {
      final id = 'm-${nextId++}';
      final envelope = await from.sessions.encryptMessage(
        bob.id,
        jsonEncode({'v': 1, 'id': id, 'groupId': null, ...fields}),
      );
      final data = {
        'messageId': id,
        'senderId': from.id,
        'encryptedBody': base64Encode(utf8.encode(envelope)),
        'groupId': null,
      };
      transport.add(data);
      await Future<void>.delayed(Duration.zero);
      await MessageProcessingQueue.forDatabase(bob.db).run(() async {});
      return data;
    }

    Future<Message> row(String id) => (bob.db.select(
      bob.db.messages,
    )..where((m) => m.id.equals(id))).getSingle();

    Future<void> seed({
      String id = 'target',
      String sender = 'alice',
      String conversation = 'alice',
      String? organizationId,
    }) async {
      await bob.db
          .into(bob.db.conversations)
          .insertOnConflictUpdate(
            ConversationsCompanion.insert(
              id: conversation,
              type: 'direct',
              organizationId: Value(organizationId),
            ),
          );
      await bob.db
          .into(bob.db.messages)
          .insert(
            MessagesCompanion.insert(
              id: id,
              conversationId: conversation,
              senderId: sender,
              body: const Value('secret'),
              replyPreview: const Value('quoted'),
              createdAt: DateTime(2026),
            ),
          );
    }

    test('stores reply fields and the forwarded flag', () async {
      final d = await deliver(alice, {
        'body': 'answer',
        'type': 'text',
        'replyTo': {'id': 'orig', 'senderId': 'bob', 'preview': 'x' * 300},
        'forwarded': true,
      });
      final m = await row(d['messageId'] as String);
      expect(m.replyToId, 'orig');
      expect(m.replySenderId, 'bob');
      expect(m.replyPreview, 'x' * 140);
      expect(m.forwarded, isTrue);
    });

    test('malformed replyTo is ignored but the message is kept', () async {
      for (final bad in <Object?>[
        'string',
        {'id': 1, 'senderId': 'a', 'preview': 'p'},
        {'id': 'a', 'senderId': 'a'},
      ]) {
        final d = await deliver(alice, {
          'body': 'hi',
          'type': 'text',
          'replyTo': bad,
        });
        final m = await row(d['messageId'] as String);
        expect(m.body, 'hi');
        expect(m.replyToId, isNull);
        expect(m.replyPreview, isNull);
        expect(m.forwarded, isFalse);
      }
      expect(errors, isEmpty);
    });

    test('delete from the author tombstones the message and acks', () async {
      await seed();
      final d = await deliver(alice, {'body': 'target', 'type': 'delete'});
      final m = await row('target');
      expect(m.deleted, isTrue);
      expect(m.body, isNull);
      expect(m.type, 'text');
      expect(m.replyPreview, isNull);
      expect(acks, [d['messageId']]);
      expect(errors, isEmpty);
    });

    test(
      'delete never creates a row or bumps unread / lastMessageAt',
      () async {
        await seed();
        final d = await deliver(alice, {'body': 'target', 'type': 'delete'});
        expect(await bob.db.select(bob.db.messages).get(), hasLength(1));
        expect(
          (await (bob.db.select(
            bob.db.messages,
          )..where((m) => m.id.equals(d['messageId'] as String))).get()),
          isEmpty,
        );
        final c = await bob.db.select(bob.db.conversations).getSingle();
        expect(c.unreadCount, 0);
        expect(c.lastMessageAt, isNull);
      },
    );

    test('delete from someone else is ignored but acked', () async {
      await seed(); // alice's message in the conversation "alice"
      final d = await deliver(carol, {'body': 'target', 'type': 'delete'});
      expect((await row('target')).deleted, isFalse);
      expect(acks, [d['messageId']]);
    });

    test(
      'delete aimed at a message of another conversation is ignored',
      () async {
        await seed(conversation: 'some-group');
        final d = await deliver(alice, {'body': 'target', 'type': 'delete'});
        expect((await row('target')).deleted, isFalse);
        expect(acks, [d['messageId']]);
      },
    );

    test('delete of an unknown id is ignored but acked', () async {
      final d = await deliver(alice, {'body': 'nope', 'type': 'delete'});
      expect(acks, [d['messageId']]);
      expect(errors, isEmpty);
    });

    test('delete in a business conversation is ignored but acked', () async {
      await seed(organizationId: 'org');
      final d = await deliver(alice, {'body': 'target', 'type': 'delete'});
      expect((await row('target')).deleted, isFalse);
      expect(acks, [d['messageId']]);
    });

    test('a redelivered delete is acked again without error', () async {
      await seed();
      final d = await deliver(alice, {'body': 'target', 'type': 'delete'});
      transport.add(d);
      await Future<void>.delayed(Duration.zero);
      await MessageProcessingQueue.forDatabase(bob.db).run(() async {});
      expect(acks, [d['messageId'], d['messageId']]);
      expect(errors, isEmpty);
      expect((await row('target')).deleted, isTrue);
    });
  });

  group('controller', () {
    late TestDevice alice;
    late TestDevice bob;
    late _Transport transport;
    late _Api api;
    late MessageInboxService inbox;
    late ChatController controller;

    Future<void> setUpChat({
      String id = 'bob',
      String type = 'direct',
      String? organizationId,
    }) async {
      await alice.db
          .into(alice.db.conversations)
          .insert(
            ConversationsCompanion.insert(
              id: id,
              type: type,
              title: const Value('Team'),
              organizationId: Value(organizationId),
            ),
          );
      controller = ChatController(
        database: alice.db,
        signalRClient: transport,
        sessionManager: alice.sessions,
        inbox: inbox,
        apiClient: api,
        conversationId: id,
        directory: alice.directory,
      );
    }

    setUp(() async {
      alice = await TestDevice.create('alice');
      bob = await TestDevice.create('bob');
      transport = _Transport();
      api = _Api([bob]);
      inbox = MessageInboxService(
        database: alice.db,
        sessionManager: alice.sessions,
        incomingMessages: const Stream.empty(),
      );
    });
    tearDown(() async {
      controller.dispose();
      await inbox.dispose();
      transport.dispose();
      await alice.close();
      await bob.close();
    });

    Future<Map<String, dynamic>> lastPayload() async =>
        jsonDecode(
              await bob.sessions.decryptMessage(
                alice.id,
                utf8.decode(base64Decode(transport.sent.last['bob']!)),
              ),
            )
            as Map<String, dynamic>;

    Future<List<Message>> allRows() => alice.db.select(alice.db.messages).get();

    test(
      'reply attaches to the next message, travels in the payload and clears',
      () async {
        await setUpChat();
        final original = Message(
          id: 'orig',
          conversationId: 'bob',
          senderId: 'bob',
          body: 'y' * 200,
          type: 'text',
          status: 'delivered',
          createdAt: DateTime(2026),
          forwarded: false,
          deleted: false,
        );
        controller.startReply(original);
        expect(controller.replyingTo, original);
        await controller.sendMessage('answer');
        expect(controller.replyingTo, isNull);
        final sent = (await allRows()).single;
        expect(sent.replyToId, 'orig');
        expect(sent.replySenderId, 'bob');
        expect(sent.replyPreview, 'y' * 140);
        final payload = await lastPayload();
        expect(payload['replyTo'], {
          'id': 'orig',
          'senderId': 'bob',
          'preview': 'y' * 140,
        });
        expect(payload.containsKey('forwarded'), isFalse);
        // The next message is a plain one again.
        await controller.sendMessage('plain');
        expect((await lastPayload()).containsKey('replyTo'), isFalse);
      },
    );

    test('cancelReply drops the pending quote', () async {
      await setUpChat();
      controller.startReply(
        Message(
          id: 'o',
          conversationId: 'bob',
          senderId: 'bob',
          type: 'text',
          status: 'sent',
          createdAt: DateTime(2026),
          forwarded: false,
          deleted: false,
        ),
      );
      controller.cancelReply();
      expect(controller.replyingTo, isNull);
    });

    test('sendForwarded marks the payload as forwarded', () async {
      await setUpChat();
      await controller.sendForwarded(body: 'fwd', type: 'text');
      expect((await allRows()).single.forwarded, isTrue);
      expect(await lastPayload(), containsPair('forwarded', true));
    });

    test('deleteForMe removes the row and its outbox entry', () async {
      await setUpChat();
      transport.fail = true;
      await controller.sendMessage('oops');
      final failed = (await allRows()).single;
      expect(failed.status, 'failed');
      await controller.deleteForMe(failed.id);
      expect(await allRows(), isEmpty);
      expect(
        await (alice.db.select(
          alice.db.backupState,
        )..where((s) => s.key.like('outbox:%'))).get(),
        isEmpty,
      );
    });

    test(
      'deleteForEveryone tombstones only after the send succeeded',
      () async {
        await setUpChat();
        await controller.sendMessage('secret');
        final original = (await allRows()).single;
        expect(original.status, 'sent');
        expect(await controller.deleteForEveryone(original.id), isTrue);
        final rows = await allRows();
        expect(rows, hasLength(1)); // the control row is gone again
        expect(rows.single.deleted, isTrue);
        expect(rows.single.body, isNull);
        final payload = await lastPayload();
        expect(payload['type'], 'delete');
        expect(payload['body'], original.id);
        // lastMessageAt was not touched by the control message.
        final conversation = await alice.db
            .select(alice.db.conversations)
            .getSingle();
        expect(conversation.lastMessageAt, original.createdAt);
      },
    );

    test(
      'deleteForEveryone failure leaves the original and returns false',
      () async {
        await setUpChat();
        await controller.sendMessage('secret');
        transport.fail = true;
        final original = (await allRows()).single;
        expect(await controller.deleteForEveryone(original.id), isFalse);
        final rows = await allRows();
        expect(rows.single.deleted, isFalse);
        expect(rows.single.body, 'secret');
        expect(
          await (alice.db.select(
            alice.db.backupState,
          )..where((s) => s.key.like('outbox:%'))).get(),
          isEmpty,
        );
      },
    );

    test('deleteForEveryone refuses a business conversation', () async {
      await setUpChat(organizationId: 'org');
      await controller.sendMessage('contract');
      final sentBefore = transport.sent.length;
      expect(
        await controller.deleteForEveryone((await allRows()).single.id),
        isFalse,
      );
      expect(transport.sent.length, sentBefore);
      expect((await allRows()).single.deleted, isFalse);
    });

    test(
      'deleteForEveryone in a group fails closed when the lookup throws',
      () async {
        await setUpChat(id: 'grp', type: 'group');
        await controller.sendMessage('hi group');
        final id = (await allRows()).single.id;
        _infoMode = 'broken';
        expect(await controller.deleteForEveryone(id), isFalse);
        _infoMode = 'business';
        expect(await controller.deleteForEveryone(id), isFalse);
        expect((await allRows()).single.deleted, isFalse);
      },
    );

    test('deleteForEveryone refuses somebody else\'s message', () async {
      await setUpChat();
      await alice.db
          .into(alice.db.messages)
          .insert(
            MessagesCompanion.insert(
              id: 'theirs',
              conversationId: 'bob',
              senderId: 'bob',
              body: const Value('hello'),
              createdAt: DateTime(2026),
            ),
          );
      expect(await controller.deleteForEveryone('theirs'), isFalse);
    });

    test('control rows never appear in messages', () async {
      await setUpChat();
      await alice.db
          .into(alice.db.messages)
          .insert(
            MessagesCompanion.insert(
              id: 'ctl',
              conversationId: 'bob',
              senderId: 'alice',
              body: const Value('whatever'),
              type: const Value('delete'),
              createdAt: DateTime(2026),
            ),
          );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(controller.messages, isEmpty);
    });
  });
}
