import 'dart:async';
import 'dart:convert';

import 'package:calltype/core/storage/database.dart';
import 'package:calltype/features/chat/message_inbox_service.dart';
import 'package:calltype/features/chat/reactions.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_device.dart';

/// The receiving side of `type: reaction` (spec 2026-11-07-message-reactions):
/// validation, authorization, ordering and what a reaction must NOT do.
void main() {
  late TestDevice alice; // reacts
  late TestDevice carol; // somebody else
  late TestDevice bob; // the receiver under test
  late StreamController<Map<String, dynamic>> transport;
  late MessageInboxService inbox;
  late List<String> acks;
  late List<Object> errors;
  late List<AppliedReaction> applied;
  var nextId = 0;

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    alice = await TestDevice.create('alice');
    carol = await TestDevice.create('carol');
    bob = await TestDevice.create('bob');
    transport = StreamController<Map<String, dynamic>>();
    acks = [];
    errors = [];
    applied = [];
    inbox = MessageInboxService(
      database: bob.db,
      sessionManager: bob.sessions,
      directory: () => bob.directory,
      incomingMessages: transport.stream,
      acknowledge: (sender, id) async => acks.add(id),
    );
    inbox.errors.listen(errors.add);
    inbox.appliedReactions.listen(applied.add);
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
    Map<String, dynamic> fields, {
    String? groupId,
  }) async {
    final id = 'r-${nextId++}';
    final envelope = await from.sessions.encryptMessage(
      bob.id,
      jsonEncode({'v': 1, 'id': id, 'groupId': groupId, ...fields}),
    );
    final data = {
      'messageId': id,
      'senderId': from.id,
      'encryptedBody': base64Encode(utf8.encode(envelope)),
      'groupId': groupId,
    };
    transport.add(data);
    await Future<void>.delayed(Duration.zero);
    await MessageProcessingQueue.forDatabase(bob.db).run(() async {});
    return data;
  }

  Map<String, dynamic> reaction(
    String emoji, {
    String target = 'target',
    String createdAt = '2026-11-07T10:00:00.000Z',
  }) => {
    'type': 'reaction',
    'body': ReactionPayload(targetId: target, emoji: emoji).encode(),
    'createdAt': createdAt,
  };

  Future<void> conversation(String id, {String? organizationId}) => bob.db
      .into(bob.db.conversations)
      .insertOnConflictUpdate(
        ConversationsCompanion.insert(
          id: id,
          type: id == 'g' ? 'group' : 'direct',
          organizationId: Value(organizationId),
        ),
      );

  /// Bob's own message in the 1:1 with alice (the usual target).
  Future<void> seed({
    String id = 'target',
    String conversationId = 'alice',
    String type = 'text',
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
            body: const Value('ship it?'),
            type: Value(type),
            deleted: Value(deleted),
            createdAt: DateTime.utc(2026),
          ),
        );
  }

  Future<List<MessageReaction>> reactions() =>
      bob.db.select(bob.db.messageReactions).get();

  test('stores the reaction under the authenticated sender; no row, no '
      'unread, no reorder; acked and remembered', () async {
    await seed();
    final d = await deliver(alice, reaction('👍'));
    final row = (await reactions()).single;
    expect(row.messageId, 'target');
    expect(row.reactorId, 'alice');
    expect(row.conversationId, 'alice');
    expect(row.emoji, '👍');
    expect(row.reactedAt, DateTime.utc(2026, 11, 7, 10).millisecondsSinceEpoch);
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
    expect(applied.single.target?.id, 'target');
    expect(applied.single.reactorId, 'alice');
  });

  test('a redelivered reaction is acked again without error', () async {
    await seed();
    final d = await deliver(alice, reaction('👍'));
    transport.add(d);
    await Future<void>.delayed(Duration.zero);
    await MessageProcessingQueue.forDatabase(bob.db).run(() async {});
    expect(acks, [d['messageId'], d['messageId']]);
    expect(errors, isEmpty);
    expect(applied, hasLength(1));
  });

  test('invalid bodies and emojis are acked and dropped', () async {
    await seed();
    final bad = [
      {'type': 'reaction', 'body': 'not json'},
      {'type': 'reaction', 'body': '{"targetId":"target","emoji":"lol"}'},
      {'type': 'reaction', 'body': '{"targetId":"target","emoji":"👍👍"}'},
      {'type': 'reaction', 'body': '{"emoji":"👍"}'},
    ];
    final ids = [for (final b in bad) (await deliver(alice, b))['messageId']];
    expect(acks, ids);
    expect(await reactions(), isEmpty);
    expect(errors, isEmpty);
  });

  test('last writer wins: an older reaction does not override, a removal '
      'is not resurrected', () async {
    await seed();
    await deliver(alice, reaction('❤️', createdAt: '2026-11-07T10:00:10.000Z'));
    await deliver(alice, reaction('👍', createdAt: '2026-11-07T10:00:05.000Z'));
    expect((await reactions()).single.emoji, '❤️');
    await deliver(alice, reaction('', createdAt: '2026-11-07T10:00:20.000Z'));
    expect((await reactions()).single.emoji, '');
    await deliver(alice, reaction('😂', createdAt: '2026-11-07T10:00:15.000Z'));
    expect((await reactions()).single.emoji, '');
    // Within the same millisecond-precise instant the later arrival wins.
    await deliver(alice, reaction('🙏', createdAt: '2026-11-07T10:00:20.000Z'));
    expect((await reactions()).single.emoji, '🙏');
  });

  test('two people keep one reaction each (group)', () async {
    await seed(conversationId: 'g');
    await deliver(alice, reaction('👍'), groupId: 'g');
    await deliver(carol, reaction('👍'), groupId: 'g');
    await deliver(
      carol,
      reaction('😮', createdAt: '2026-11-07T10:00:01Z'),
      groupId: 'g',
    );
    final rows = await reactions();
    expect(
      {for (final r in rows) r.reactorId: r.emoji},
      {'alice': '👍', 'carol': '😮'},
    );
  });

  test('a target in another conversation is never touched', () async {
    // The message lives in bob's chat with carol; alice names its id.
    await seed(conversationId: 'carol');
    await conversation('alice');
    await deliver(alice, reaction('💩'));
    expect(await reactions(), isEmpty);
  });

  test(
    'a reaction before its target is kept, bound to its conversation',
    () async {
      await conversation('alice');
      await deliver(alice, reaction('👍', target: 'later'));
      final row = (await reactions()).single;
      expect(row.messageId, 'later');
      expect(row.conversationId, 'alice');
      expect(applied.single.target, isNull);
    },
  );

  test(
    'no reaction on a tombstone, a call log line or a device notice',
    () async {
      await seed(deleted: true);
      await seed(id: 'call', type: 'call-event');
      await seed(id: 'notice', type: 'device-change');
      await deliver(alice, reaction('👍'));
      await deliver(alice, reaction('👍', target: 'call'));
      await deliver(alice, reaction('👍', target: 'notice'));
      expect(await reactions(), isEmpty);
      expect(acks, hasLength(3));
    },
  );

  test('no reaction in a business conversation or an unknown chat', () async {
    await deliver(alice, reaction('👍', target: 'x'));
    expect(
      await bob.db.select(bob.db.conversations).get(),
      isEmpty,
      reason: 'a reaction never creates a conversation',
    );
    await conversation('alice', organizationId: 'org');
    await deliver(alice, reaction('👍', target: 'y'));
    expect(await reactions(), isEmpty);
  });

  test('group: a member\'s reaction lands in the group', () async {
    await seed(conversationId: 'g');
    await deliver(alice, reaction('🎉'), groupId: 'g');
    final row = (await reactions()).single;
    expect(row.conversationId, 'g');
    expect(row.reactorId, 'alice');
    // A 1:1 delivery cannot claim the group's message.
    await deliver(carol, reaction('🙃'));
    expect(await reactions(), hasLength(1));
  });

  test('a delete for everyone removes the target\'s reactions', () async {
    await seed();
    await bob.db
        .into(bob.db.messages)
        .insert(
          MessagesCompanion.insert(
            id: 'alices',
            conversationId: 'alice',
            senderId: 'alice',
            body: const Value('oops'),
            createdAt: DateTime.utc(2026),
          ),
        );
    await deliver(alice, reaction('👍', target: 'alices'));
    await deliver(alice, reaction('👍'));
    expect(await reactions(), hasLength(2));
    await deliver(alice, {'type': 'delete', 'body': 'alices'});
    expect((await reactions()).single.messageId, 'target');
  });
}
