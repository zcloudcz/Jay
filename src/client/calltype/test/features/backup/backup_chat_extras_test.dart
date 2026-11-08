import 'dart:convert';

import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:calltype/features/backup/backup_controller.dart';
import 'package:calltype/features/backup/backup_import.dart';
import 'package:calltype/features/chat/polls.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Polls, votes and pins in the encrypted backup (spec
/// 2026-11-08-chat-extras): carried additively, a poll as text + `poll`.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final lunch = PollPayload.create(
    question: 'Lunch?',
    options: ['Pizza', 'Sushi'],
  );

  test('round trip keeps polls, votes and pins; in-flight control rows stay '
      'out', () async {
    final source = AppDatabase.forTesting(NativeDatabase.memory());
    final target = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(source.close);
    addTearDown(target.close);
    await source
        .into(source.conversations)
        .insert(ConversationsCompanion.insert(id: 'chat', type: 'direct'));
    for (final (id, type, body) in [
      ('poll', pollMessageType, lunch.encode()),
      ('pinctl', 'pin', '{"targetId":"poll","pinned":true}'),
      ('votectl', pollVoteType, '{"pollId":"poll","options":[0]}'),
    ]) {
      await source
          .into(source.messages)
          .insert(
            MessagesCompanion.insert(
              id: id,
              conversationId: 'chat',
              senderId: 'peer',
              body: Value(body),
              type: Value(type),
              createdAt: DateTime.utc(2026),
            ),
          );
    }
    await source
        .into(source.messagePins)
        .insert(
          MessagePinsCompanion.insert(
            conversationId: 'chat',
            messageId: 'poll',
            pinned: true,
            pinnedBy: 'peer',
            changedAt: 1767225600123,
          ),
        );
    await source
        .into(source.pollVotes)
        .insert(
          PollVotesCompanion.insert(
            pollId: 'poll',
            voterId: 'peer',
            conversationId: 'chat',
            options: '[1]',
            votedAt: 1767225600456,
          ),
        );
    Uint8List? encrypted;
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            dynamic data;
            if (options.method == 'POST') {
              final file = (options.data as FormData).files.single.value;
              encrypted = Uint8List.fromList(
                await file.finalize().expand((bytes) => bytes).toList(),
              );
              data = {'id': 1};
            } else if (options.path.endsWith('/1')) {
              data = encrypted;
            } else {
              data = [
                {'id': 1},
              ];
            }
            handler.resolve(Response(requestOptions: options, data: data));
          },
        ),
      );
    final api = ApiClient(baseUrl: 'https://example.test', dio: dio);
    final creator = BackupController(
      database: source,
      apiClient: api,
      accountId: 'account',
    );
    await creator.createBackup('roundtrip passphrase');
    expect(creator.status, BackupStatus.done);
    final restore = BackupController(
      database: target,
      apiClient: api,
      accountId: 'account',
    );
    await restore.restore('roundtrip passphrase');
    expect(restore.status, BackupStatus.done);

    final message = (await target.select(target.messages).get()).single;
    expect(message.id, 'poll');
    expect(message.type, pollMessageType);
    expect(PollPayload.tryDecode(message.body), lunch);
    final pin = (await target.select(target.messagePins).get()).single;
    expect(pin.messageId, 'poll');
    expect(pin.pinned, isTrue);
    expect(pin.changedAt, 1767225600123);
    final vote = (await target.select(target.pollVotes).get()).single;
    expect(decodeVoteOptions(vote.options), [1]);
    expect(vote.votedAt, 1767225600456);
  });

  group('importBackup', () {
    late AppDatabase db;
    setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    Map<String, dynamic> backup({
      required List<Map<String, dynamic>> messages,
      Object? pins,
      Object? votes,
    }) => {
      'version': 1,
      'contacts': <Object>[],
      'conversations': [
        {'id': 'chat', 'type': 'direct'},
      ],
      'messages': messages,
      'pins': ?pins,
      'pollVotes': ?votes,
    };

    Map<String, dynamic> row(
      String id,
      String type,
      String body, [
      Object? poll,
    ]) => {
      'id': id,
      'conversationId': 'chat',
      'senderId': 'peer',
      'body': body,
      'type': type,
      'status': 'delivered',
      'createdAt': '2026-01-01T00:00:00.000Z',
      'poll': ?poll,
    };

    test('text + valid poll becomes a poll; an invalid one stays text; '
        'control rows are skipped', () async {
      await importBackup(
        db,
        backup(
          messages: [
            row('p', 'text', 'fallback', lunch.toJson()),
            row('bad', 'text', 'fallback 2', {'v': 9}),
            row('c1', 'pin', '{}'),
            row('c2', pollVoteType, '{}'),
          ],
        ),
      );
      final rows = {
        for (final m in await db.select(db.messages).get()) m.id: m,
      };
      expect(rows.keys.toSet(), {'p', 'bad'});
      expect(rows['p']!.type, pollMessageType);
      expect(PollPayload.tryDecode(rows['p']!.body), lunch);
      expect(rows['bad']!.type, 'text');
      expect(rows['bad']!.body, 'fallback 2');
    });

    test('bad pin and vote rows are skipped, never fail the restore', () async {
      await importBackup(
        db,
        backup(
          messages: [],
          pins: [
            {
              'conversationId': 'chat',
              'messageId': 'm',
              'pinned': true,
              'pinnedBy': 'peer',
              'changedAt': 5,
            },
            {'conversationId': 'other', 'messageId': 'm'},
            'garbage',
          ],
          votes: [
            {
              'pollId': 'p',
              'voterId': 'peer',
              'conversationId': 'chat',
              'options': [2, 0],
              'votedAt': 6,
            },
            {
              'pollId': 'p',
              'voterId': 'x',
              'conversationId': 'chat',
              'options': [99],
              'votedAt': 6,
            },
          ],
        ),
      );
      expect(await db.select(db.messagePins).get(), hasLength(1));
      final vote = (await db.select(db.pollVotes).get()).single;
      expect(jsonDecode(vote.options), [0, 2]);
    });
  });
}
