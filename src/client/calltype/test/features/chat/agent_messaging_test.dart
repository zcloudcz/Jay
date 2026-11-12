import 'dart:async';
import 'dart:convert';

import 'package:calltype_core/network/api_client.dart';
import 'package:calltype/core/network/signalr_client.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:calltype/features/chat/bot_commands.dart';
import 'package:calltype/features/chat/chat_controller.dart';
import 'package:calltype/features/chat/message_inbox_service.dart';
import 'package:calltype_core/messaging/agent_payload.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_device.dart';

/// Agent messaging (contract sections 1 and 8): mentions, buttons and edits
/// on the receiving side (inbox) and the sending side (controller), against
/// real in-memory databases and real ratchets.

/// `GET /groups/{id}` for the business check and `GET /devices/{id}/
/// bot-commands`, answered at the HTTP layer with the exact contract shapes.
String _groupMode = 'none';
final _botCommandCalls = <String>[];

Dio _fakeDio() {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        final path = options.path;
        final commands = RegExp(
          r'^/devices/([^/]+)/bot-commands$',
        ).firstMatch(path);
        if (commands != null) {
          _botCommandCalls.add(commands.group(1)!);
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              // Contract section 4: 200 -> {"commands": [...]}.
              data: <String, dynamic>{
                'commands': [
                  {'command': 'help', 'description': 'Show help'},
                  {'command': 'new', 'description': 'New conversation'},
                ],
              },
            ),
          );
          return;
        }
        handler.resolve(
          Response(
            requestOptions: options,
            data: _groupMode == 'business'
                ? <String, dynamic>{
                    'organizationId': 'org',
                    'organizationName': 'Acme',
                    'auditorDeviceId': 'aud',
                  }
                : <String, dynamic>{},
          ),
        );
      },
    ),
  );
  return dio;
}

class _Api extends ApiClient {
  _Api(this.peers) : super(baseUrl: 'http://unused', dio: _fakeDio());
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
  final ids = <String>[];

  @override
  Future<void> sendDirectFanout(
    String recipientIdentityId,
    Map<String, String> encryptedPayloads, {
    required String messageId,
    bool silent = false,
  }) async {
    sent.add(Map.of(encryptedPayloads));
    ids.add(messageId);
    if (fail) throw StateError('offline');
  }

  @override
  Future<void> sendGroupFanout(
    String groupId,
    Map<String, String> encryptedPayloads, {
    required String messageId,
    bool silent = false,
  }) async {
    sent.add(Map.of(encryptedPayloads));
    ids.add(messageId);
    if (fail) throw StateError('offline');
  }
}

void main() {
  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    _groupMode = 'none';
    _botCommandCalls.clear();
  });

  group('inbox', () {
    late TestDevice alice; // the bot / author
    late TestDevice carol; // somebody else
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
        directory: () => bob.directory,
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

    /// The bot's original message, as the inbox would have stored it.
    Future<void> seed({
      String type = 'text',
      bool deleted = false,
      String sender = 'alice',
      String? actionsJson,
    }) async {
      await bob.db
          .into(bob.db.conversations)
          .insertOnConflictUpdate(
            ConversationsCompanion.insert(id: 'alice', type: 'direct'),
          );
      await bob.db
          .into(bob.db.messages)
          .insert(
            MessagesCompanion.insert(
              id: 'target',
              conversationId: 'alice',
              senderId: sender,
              body: const Value('working...'),
              type: Value(type),
              deleted: Value(deleted),
              actionsJson: Value(actionsJson),
              createdAt: DateTime.utc(2026),
            ),
          );
    }

    Map<String, dynamic> edit(
      String body, {
      String createdAt = '2026-11-05T10:00:00.000Z',
      Object? actions,
      bool withActions = false,
    }) => {
      'type': 'edit',
      'body': body,
      'editOf': 'target',
      'createdAt': createdAt,
      if (withActions) 'actions': actions,
    };

    test(
      'stores valid buttons of a text message, drops invalid ones',
      () async {
        final d = await deliver(alice, {
          'type': 'text',
          'body': 'Run rm -rf build?',
          'actions': [
            {'id': 'approve:r1:q1:once', 'label': 'Approve once'},
            {'id': 'bad id with spaces', 'label': 'x'},
            {'id': 'deny', 'label': 'Deny'},
          ],
          'mentions': ['B0000000-0000-4000-8000-000000000001'],
        });
        final m = await row(d['messageId'] as String);
        expect(decodeActionsJson(m.actionsJson), const [
          MessageButton(id: 'approve:r1:q1:once', label: 'Approve once'),
          MessageButton(id: 'deny', label: 'Deny'),
        ]);
        expect(errors, isEmpty);
      },
    );

    test('a message without buttons stores none', () async {
      final d = await deliver(alice, {'type': 'text', 'body': 'hi'});
      expect((await row(d['messageId'] as String)).actionsJson, isNull);
    });

    test('an edit from the author replaces the text, acks, no new row, '
        'no unread', () async {
      await seed();
      final d = await deliver(alice, edit('Done: 3 files'));
      final m = await row('target');
      expect(m.body, 'Done: 3 files');
      expect(
        m.editedAt!.isAtSameMomentAs(DateTime.utc(2026, 11, 5, 10)),
        isTrue,
      );
      expect(await bob.db.select(bob.db.messages).get(), hasLength(1));
      final c = await bob.db.select(bob.db.conversations).getSingle();
      expect(c.unreadCount, 0);
      expect(c.lastMessageAt, isNull);
      expect(acks, [d['messageId']]);
      expect(
        await (bob.db.select(bob.db.backupState)
              ..where((s) => s.key.equals('control:${d['messageId']}')))
            .getSingleOrNull(),
        isNotNull,
      );
      expect(errors, isEmpty);
    });

    test('an edit from somebody else is dropped but acked', () async {
      await seed();
      final d = await deliver(carol, edit('hijacked'));
      expect((await row('target')).body, 'working...');
      expect((await row('target')).editedAt, isNull);
      expect(acks, [d['messageId']]);
    });

    test('an edit of a deleted or non-text message is dropped', () async {
      await seed(deleted: true);
      final d = await deliver(alice, edit('back from the dead'));
      expect((await row('target')).body, 'working...');
      expect(acks, [d['messageId']]);
      await bob.db.delete(bob.db.messages).go();
      await seed(type: 'file');
      await deliver(alice, edit('not a file'));
      expect((await row('target')).body, 'working...');
    });

    test(
      'an edit of an unknown or missing target is dropped but acked',
      () async {
        final d1 = await deliver(alice, edit('nobody'));
        final d2 = await deliver(alice, {'type': 'edit', 'body': 'no editOf'});
        expect(acks, [d1['messageId'], d2['messageId']]);
        expect(await bob.db.select(bob.db.messages).get(), isEmpty);
        expect(errors, isEmpty);
      },
    );

    test('out-of-order edits: the newer createdAt wins', () async {
      await seed();
      await deliver(
        alice,
        edit('final answer', createdAt: '2026-11-05T10:00:10.000Z'),
      );
      await deliver(
        alice,
        edit('still working', createdAt: '2026-11-05T10:00:05.000Z'),
      );
      final m = await row('target');
      expect(m.body, 'final answer');
      expect(
        m.editedAt!.isAtSameMomentAs(DateTime.utc(2026, 11, 5, 10, 0, 10)),
        isTrue,
      );
    });

    test('two edits within the same second apply in arrival order', () async {
      // drift stores whole seconds; a final answer right after a progress
      // edit must not be lost (see _applyEdit).
      await seed();
      await deliver(
        alice,
        edit('progress', createdAt: '2026-11-05T10:00:05.100Z'),
      );
      await deliver(
        alice,
        edit('answer', createdAt: '2026-11-05T10:00:05.900Z'),
      );
      expect((await row('target')).body, 'answer');
    });

    test('actions: present replaces, empty removes, absent keeps', () async {
      await seed(
        actionsJson: encodeActionsJson(const [
          MessageButton(id: 'a', label: 'A'),
        ]),
      );
      await deliver(alice, edit('kept', createdAt: '2026-11-05T10:00:01Z'));
      expect(decodeActionsJson((await row('target')).actionsJson), const [
        MessageButton(id: 'a', label: 'A'),
      ]);
      await deliver(
        alice,
        edit(
          'replaced',
          createdAt: '2026-11-05T10:00:02Z',
          withActions: true,
          actions: [
            {'id': 'b', 'label': 'B'},
          ],
        ),
      );
      expect(decodeActionsJson((await row('target')).actionsJson), const [
        MessageButton(id: 'b', label: 'B'),
      ]);
      await deliver(
        alice,
        edit(
          'Approved',
          createdAt: '2026-11-05T10:00:03Z',
          withActions: true,
          actions: const <Object>[],
        ),
      );
      final m = await row('target');
      expect(m.body, 'Approved');
      expect(m.actionsJson, isNull);
    });

    test('a redelivered edit is acked again without error', () async {
      await seed();
      final d = await deliver(alice, edit('once'));
      transport.add(d);
      await Future<void>.delayed(Duration.zero);
      await MessageProcessingQueue.forDatabase(bob.db).run(() async {});
      expect(acks, [d['messageId'], d['messageId']]);
      expect(errors, isEmpty);
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
      BotCommandsCache? cache,
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
        commandsCache: cache ?? BotCommandsCache(),
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
        directory: () => alice.directory,
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

    Future<List<BackupStateData>> extras() => (alice.db.select(
      alice.db.backupState,
    )..where((s) => s.key.like('extra:%'))).get();

    test('mentions travel as lower-cased identity ids', () async {
      await setUpChat();
      await controller.sendMessage(
        '@Hermes deploy',
        mentions: ['B0000000-0000-4000-8000-000000000001'],
      );
      final payload = await lastPayload();
      expect(payload['mentions'], ['b0000000-0000-4000-8000-000000000001']);
      expect(payload['body'], '@Hermes deploy');
      expect(await extras(), isEmpty);
      // No mention picked: no key at all.
      await controller.sendMessage('plain');
      expect((await lastPayload()).containsKey('mentions'), isFalse);
    });

    test('extra keys survive a send that failed before the outbox', () async {
      await setUpChat();
      // getGroupMembers is not used for a direct chat; break the session
      // lookup instead so the FIRST attempt dies before the outbox exists.
      final broken = _Api([]);
      final first = ChatController(
        database: alice.db,
        signalRClient: transport,
        sessionManager: alice.sessions,
        inbox: inbox,
        apiClient: broken,
        conversationId: 'bob',
        directory: alice.directory,
      );
      await first.sendMessage('@Hermes hi', mentions: ['bob-identity']);
      first.dispose();
      final failed = (await allRows()).single;
      expect(failed.status, 'failed');
      expect(await extras(), hasLength(1));
      await controller.retryMessage(failed.id);
      expect((await allRows()).single.status, 'sent');
      expect((await lastPayload())['mentions'], ['bob-identity']);
      expect(await extras(), isEmpty);
    });

    test('a button tap sends the label, quotes the bot message and carries '
        'the action', () async {
      await setUpChat();
      final botMessage = Message(
        id: 'bot-msg',
        conversationId: 'bob',
        senderId: 'bob',
        body: 'Approve the command?',
        type: 'text',
        status: 'delivered',
        createdAt: DateTime(2026),
        forwarded: false,
        deleted: false,
        actionsJson: encodeActionsJson(const [
          MessageButton(id: 'approve:r1:q1:once', label: 'Approve once'),
        ]),
      );
      await controller.sendAction(
        botMessage,
        const MessageButton(id: 'approve:r1:q1:once', label: 'Approve once'),
      );
      final payload = await lastPayload();
      expect(payload['type'], 'text');
      expect(payload['body'], 'Approve once');
      expect(payload['replyTo'], {
        'id': 'bot-msg',
        'senderId': 'bob',
        'preview': 'Approve the command?',
      });
      expect(payload['action'], {
        'messageId': 'bot-msg',
        'id': 'approve:r1:q1:once',
      });
      final sent = (await allRows()).single;
      expect(sent.replyToId, 'bot-msg');
    });

    test(
      'a button tap does not consume the reply the user is composing',
      () async {
        await setUpChat();
        final other = Message(
          id: 'other',
          conversationId: 'bob',
          senderId: 'bob',
          body: 'x',
          type: 'text',
          status: 'delivered',
          createdAt: DateTime(2026),
          forwarded: false,
          deleted: false,
        );
        controller.startReply(other);
        await controller.sendAction(
          other.copyWith(id: 'bot'),
          const MessageButton(id: 'ok', label: 'OK'),
        );
        expect(controller.replyingTo, other);
        expect((await lastPayload())['replyTo']['id'], 'bot');
      },
    );

    test('edit sends type edit with editOf and the full body, then updates '
        'the local copy', () async {
      await setUpChat();
      await controller.sendMessage('helo');
      final original = (await allRows()).single;
      expect(await controller.editMessage(original.id, 'hello'), isTrue);
      final payload = await lastPayload();
      expect(payload['type'], 'edit');
      expect(payload['editOf'], original.id);
      expect(payload['body'], 'hello');
      expect(payload['to'], 'bob');
      expect(payload['createdAt'], isA<String>());
      final rows = await allRows();
      expect(rows, hasLength(1)); // the control row is gone again
      expect(rows.single.body, 'hello');
      expect(rows.single.editedAt, isNotNull);
      expect(await extras(), isEmpty);
      // Not a new message: lastMessageAt stays at the original.
      final conversation = await alice.db
          .select(alice.db.conversations)
          .getSingle();
      expect(conversation.lastMessageAt, original.createdAt);
    });

    test('the peer applies the edit the controller sent', () async {
      await setUpChat();
      await controller.sendMessage('first');
      final original = (await allRows()).single;
      await controller.editMessage(original.id, 'second');
      final acks = <String>[];
      final incoming = StreamController<Map<String, dynamic>>();
      final bobInbox = MessageInboxService(
        database: bob.db,
        sessionManager: bob.sessions,
        directory: () => bob.directory,
        incomingMessages: incoming.stream,
        acknowledge: (_, id) async => acks.add(id),
      )..start();
      for (final (i, envelopes) in transport.sent.indexed) {
        incoming.add({
          'messageId': transport.ids[i],
          'senderId': alice.id,
          'encryptedBody': envelopes['bob'],
          'groupId': null,
        });
      }
      await Future<void>.delayed(Duration.zero);
      await MessageProcessingQueue.forDatabase(bob.db).run(() async {});
      final received = await bob.db.select(bob.db.messages).getSingle();
      expect(received.id, original.id);
      expect(received.body, 'second');
      expect(received.editedAt, isNotNull);
      expect(acks, transport.ids);
      final conversation = await bob.db
          .select(bob.db.conversations)
          .getSingle();
      expect(conversation.unreadCount, 1); // the original only
      await bobInbox.dispose();
      await incoming.close();
    });

    test('edit refuses somebody else\'s message and business chats', () async {
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
      expect(await controller.editMessage('theirs', 'changed'), isFalse);
      expect(transport.sent, isEmpty);
      controller.dispose();
      await setUpChat(id: 'biz', type: 'group', organizationId: 'org');
      await controller.sendMessage('contract');
      final sentBefore = transport.sent.length;
      final id = (await (alice.db.select(
        alice.db.messages,
      )..where((m) => m.conversationId.equals('biz'))).getSingle()).id;
      expect(await controller.editMessage(id, 'changed'), isFalse);
      expect(transport.sent.length, sentBefore);
    });

    test(
      'edit in a group fails closed when the server says business',
      () async {
        await setUpChat(id: 'grp', type: 'group');
        await controller.sendMessage('hi group');
        final id = (await allRows()).single.id;
        _groupMode = 'business';
        expect(await controller.editMessage(id, 'changed'), isFalse);
        expect((await allRows()).single.body, 'hi group');
      },
    );

    test('a failed edit leaves the original untouched', () async {
      await setUpChat();
      await controller.sendMessage('secret');
      transport.fail = true;
      final original = (await allRows()).single;
      expect(await controller.editMessage(original.id, 'changed'), isFalse);
      final rows = await allRows();
      expect(rows.single.body, 'secret');
      expect(rows.single.editedAt, isNull);
      expect(
        await (alice.db.select(
          alice.db.backupState,
        )..where((s) => s.key.like('outbox:%') | s.key.like('extra:%'))).get(),
        isEmpty,
      );
    });

    test('edit control rows never appear in messages', () async {
      await setUpChat();
      await alice.db
          .into(alice.db.messages)
          .insert(
            MessagesCompanion.insert(
              id: 'ctl',
              conversationId: 'bob',
              senderId: 'alice',
              body: const Value('whatever'),
              type: const Value('edit'),
              createdAt: DateTime(2026),
            ),
          );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(controller.messages, isEmpty);
    });

    test('command suggestions: 1:1 inserts /cmd, a group /cmd@HANDLE, and the '
        'list is cached per bot', () async {
      final cache = BotCommandsCache();
      await setUpChat(cache: cache);
      final direct = await controller.commandSuggestions(const [
        CommandBot(deviceId: 'bot-1', handle: 'CT-BOT1-AAAA'),
      ], group: false);
      expect(direct.map((c) => c.insert), ['/help ', '/new ']);
      final grouped = await controller.commandSuggestions(const [
        CommandBot(deviceId: 'bot-1', handle: 'CT-BOT1-AAAA', name: 'Hermes'),
      ], group: true);
      expect(grouped.map((c) => c.insert), [
        '/help@CT-BOT1-AAAA ',
        '/new@CT-BOT1-AAAA ',
      ]);
      expect(grouped.first.botName, 'Hermes');
      expect(_botCommandCalls, ['bot-1']);
    });
  });
}
