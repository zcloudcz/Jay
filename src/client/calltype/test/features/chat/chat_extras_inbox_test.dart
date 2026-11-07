import 'dart:async';
import 'dart:convert';

import 'package:calltype/core/storage/database.dart';
import 'package:calltype/features/chat/message_inbox_service.dart';
import 'package:calltype/features/chat/pins.dart';
import 'package:calltype/features/chat/polls.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_device.dart';

/// The receiving side of polls, votes and pins (spec
/// 2026-11-08-chat-extras): parsing, validation, authorization, ordering and
/// what a control message must NOT do.
void main() {
  late TestDevice alice; // sends
  late TestDevice carol; // somebody else
  late TestDevice bob; // the receiver under test
  late StreamController<Map<String, dynamic>> transport;
  late MessageInboxService inbox;
  late List<String> acks;
  late List<Object> errors;
  var nextId = 0;

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
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

  /// Delivers [fields] from [from]; returns the message id.
  Future<String> deliver(
    TestDevice from,
    Map<String, dynamic> fields, {
    String? groupId,
    String? id,
  }) async {
    final messageId = id ?? 'm-${nextId++}';
    final envelope = await from.sessions.encryptMessage(
      bob.id,
      jsonEncode({'v': 1, 'id': messageId, 'groupId': groupId, ...fields}),
    );
    transport.add({
      'messageId': messageId,
      'senderId': from.id,
      'encryptedBody': base64Encode(utf8.encode(envelope)),
      'groupId': groupId,
    });
    await Future<void>.delayed(Duration.zero);
    await MessageProcessingQueue.forDatabase(bob.db).run(() async {});
    return messageId;
  }

  Future<void> conversation(String id, {String? organizationId}) => bob.db
      .into(bob.db.conversations)
      .insertOnConflictUpdate(
        ConversationsCompanion.insert(
          id: id,
          type: id == 'g' ? 'group' : 'direct',
          organizationId: Value(organizationId),
        ),
      );

  Future<void> seed({
    String id = 'target',
    String conversationId = 'alice',
    String type = 'text',
    String body = 'ship it?',
    bool deleted = false,
  }) async {
    await conversation(conversationId);
    await bob.db
        .into(bob.db.messages)
        .insert(
          MessagesCompanion.insert(
            id: id,
            conversationId: conversationId,
            senderId: 'bob',
            body: Value(body),
            type: Value(type),
            deleted: Value(deleted),
            createdAt: DateTime.utc(2026),
          ),
        );
  }

  final lunch = PollPayload.create(
    question: 'Lunch?',
    options: ['Pizza', 'Sushi', 'Salad'],
  );

  Map<String, dynamic> pollMessage(Object? poll) => {
    'type': 'text',
    'body': '📊 Lunch?\n• Pizza\n• Sushi',
    'poll': poll,
    'createdAt': '2026-11-08T10:00:00.000Z',
  };

  Map<String, dynamic> pin(
    bool pinned, {
    String target = 'target',
    String createdAt = '2026-11-08T10:00:00.000Z',
  }) => {
    'type': pinType,
    'body': PinPayload(targetId: target, pinned: pinned).encode(),
    'createdAt': createdAt,
  };

  Map<String, dynamic> vote(
    List<int> options, {
    String poll = 'poll',
    String createdAt = '2026-11-08T10:00:00.000Z',
  }) => {
    'type': pollVoteType,
    'body': jsonEncode({'pollId': poll, 'options': options}),
    'createdAt': createdAt,
  };

  Future<List<Message>> messages() => bob.db.select(bob.db.messages).get();
  Future<List<MessagePin>> pins() => bob.db.select(bob.db.messagePins).get();
  Future<List<PollVote>> votes() => bob.db.select(bob.db.pollVotes).get();

  group('poll message', () {
    test('a valid poll object becomes a poll row with the canonical body, '
        'counted as unread', () async {
      final id = await deliver(alice, pollMessage(lunch.toJson()));
      final row = (await messages()).single;
      expect(row.id, id);
      expect(row.type, pollMessageType);
      expect(PollPayload.tryDecode(row.body), lunch);
      expect(row.actionsJson, isNull);
      final chat = await (bob.db.select(
        bob.db.conversations,
      )..where((c) => c.id.equals('alice'))).getSingle();
      expect(chat.unreadCount, 1);
      expect(acks, [id]);
      expect(errors, isEmpty);
    });

    test('an invalid poll object keeps the fallback text, never drops the '
        'message', () async {
      for (final bad in [
        {
          'v': 2,
          'question': 'Q',
          'options': ['a', 'b'],
          'multiple': false,
        },
        {
          'v': 1,
          'question': 'Q',
          'options': ['a'],
          'multiple': false,
        },
        'not an object',
      ]) {
        await deliver(alice, pollMessage(bad));
      }
      final rows = await messages();
      expect(rows, hasLength(3));
      expect(rows.map((m) => m.type).toSet(), {'text'});
      expect(rows.first.body, startsWith('📊 Lunch?'));
      expect(errors, isEmpty);
    });

    test('business conversation: shown as the fallback text', () async {
      await conversation('g', organizationId: 'org');
      await deliver(alice, pollMessage(lunch.toJson()), groupId: 'g');
      final row = (await messages()).single;
      expect(row.type, 'text');
      expect(row.body, startsWith('📊 Lunch?'));
    });
  });

  group('pin', () {
    test('applies without a row, unread count or reorder; redelivery is a '
        'no-op', () async {
      await seed();
      final before = await (bob.db.select(
        bob.db.conversations,
      )..where((c) => c.id.equals('alice'))).getSingle();
      final id = await deliver(alice, pin(true));
      final row = (await pins()).single;
      expect(row.messageId, 'target');
      expect(row.conversationId, 'alice');
      expect(row.pinned, isTrue);
      expect(row.pinnedBy, 'alice');
      expect(
        row.changedAt,
        DateTime.utc(2026, 11, 8, 10).millisecondsSinceEpoch,
      );
      expect((await messages()).map((m) => m.id), ['target']);
      final after = await (bob.db.select(
        bob.db.conversations,
      )..where((c) => c.id.equals('alice'))).getSingle();
      expect(after.unreadCount, before.unreadCount);
      expect(after.lastMessageAt, before.lastMessageAt);
      expect(acks, [id]);
      // Redelivery (lost ack) is acked again by the control marker.
      await deliver(alice, pin(false), id: id);
      expect((await pins()).single.pinned, isTrue);
      expect(acks, [id, id]);
    });

    test('last writer wins; an older pin cannot undo a newer unpin', () async {
      await seed();
      await deliver(alice, pin(false, createdAt: '2026-11-08T10:00:02.000Z'));
      await deliver(alice, pin(true, createdAt: '2026-11-08T10:00:01.000Z'));
      expect((await pins()).single.pinned, isFalse);
      await deliver(alice, pin(true, createdAt: '2026-11-08T10:00:03.000Z'));
      expect((await pins()).single.pinned, isTrue);
    });

    test('dropped: target in another conversation, tombstone, business, '
        'invalid body; acked anyway', () async {
      await seed(id: 'elsewhere', conversationId: 'carol');
      await seed(id: 'gone', deleted: true);
      await conversation('g', organizationId: 'org');
      await deliver(alice, pin(true, target: 'elsewhere'));
      await deliver(alice, pin(true, target: 'gone'));
      await deliver(alice, pin(true, target: 'x'), groupId: 'g');
      await deliver(alice, {
        'type': pinType,
        'body': '{"targetId":"target"}',
        'createdAt': '2026-11-08T10:00:00.000Z',
      });
      expect(await pins(), isEmpty);
      expect(acks, hasLength(4));
      expect(errors, isEmpty);
    });

    test('a pin for a message that has not arrived is kept', () async {
      await conversation('alice');
      await deliver(alice, pin(true, target: 'later'));
      expect((await pins()).single.messageId, 'later');
    });
  });

  group('vote', () {
    Future<void> seedPoll({
      String conversationId = 'alice',
      bool multiple = false,
    }) => seed(
      id: 'poll',
      conversationId: conversationId,
      type: pollMessageType,
      body: PollPayload.create(
        question: 'Lunch?',
        options: ['Pizza', 'Sushi', 'Salad'],
        multiple: multiple,
      ).encode(),
    );

    test(
      'stored per voter identity; last writer wins; withdrawal kept',
      () async {
        await seedPoll();
        await deliver(alice, vote([1], createdAt: '2026-11-08T10:00:01.000Z'));
        var row = (await votes()).single;
        expect(row.voterId, 'alice');
        expect(decodeVoteOptions(row.options), [1]);
        await deliver(alice, vote([], createdAt: '2026-11-08T10:00:03.000Z'));
        await deliver(alice, vote([2], createdAt: '2026-11-08T10:00:02.000Z'));
        row = (await votes()).single;
        expect(decodeVoteOptions(row.options), isEmpty);
        expect((await messages()).map((m) => m.id), ['poll']);
      },
    );

    test('dropped: index out of range, several picks on single choice, '
        'poll elsewhere, not a poll, business', () async {
      await seedPoll();
      await seed(id: 'plain');
      await seed(
        id: 'carolpoll',
        conversationId: 'carol',
        type: pollMessageType,
        body: PollPayload.create(question: 'Q', options: ['a', 'b']).encode(),
      );
      await conversation('g', organizationId: 'org');
      await deliver(alice, vote([3]));
      await deliver(alice, vote([0, 1]));
      await deliver(alice, vote([0], poll: 'carolpoll'));
      await deliver(alice, vote([0], poll: 'plain'));
      await deliver(alice, vote([0], poll: 'x'), groupId: 'g');
      expect(await votes(), isEmpty);
      expect(acks, hasLength(5));
      expect(errors, isEmpty);
    });

    test('multiple choice takes several; an unknown poll is kept', () async {
      await seedPoll(multiple: true);
      await deliver(alice, vote([0, 2]));
      // A vote never opens a conversation; in a known one it may come first.
      await conversation('carol');
      await deliver(carol, vote([1], poll: 'unknown'));
      final rows = await votes();
      expect(rows, hasLength(2));
      final results = tallyPoll(
        PollPayload.tryDecode((await messages()).single.body)!,
        rows.where((v) => v.pollId == 'poll'),
        myId: 'bob',
      );
      expect(results.countOf(0), 1);
      expect(results.countOf(1), 0);
      expect(results.countOf(2), 1);
      expect(results.voterCount, 1);
      expect(results.mine, isEmpty);
    });

    test('deleting the poll for everyone removes its votes and pins', () async {
      await conversation('alice');
      final pollId = await deliver(alice, pollMessage(lunch.toJson()));
      await deliver(alice, vote([0], poll: pollId));
      await deliver(alice, pin(true, target: pollId));
      expect(await votes(), hasLength(1));
      expect(await pins(), hasLength(1));
      await deliver(alice, {
        'type': 'delete',
        'body': pollId,
        'createdAt': '2026-11-08T10:00:05.000Z',
      });
      expect(await votes(), isEmpty);
      expect(await pins(), isEmpty);
      final row = (await messages()).single;
      expect(row.deleted, isTrue);
      expect(row.type, 'text');
    });
  });
}
