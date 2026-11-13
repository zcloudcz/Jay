import 'dart:convert';

import 'package:calltype/features/backup/backup_controller.dart';
import 'package:calltype/features/backup/backup_import.dart';
import 'package:calltype/features/groups/group_topic_store.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Backup / history transfer carry the group topics (spec
/// 2026-11-13-group-topics row 17).
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  AppDatabase newDb() {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    return db;
  }

  Future<void> group(AppDatabase db, String id) => db
      .into(db.conversations)
      .insert(ConversationsCompanion.insert(id: id, type: 'group'));

  Map<String, dynamic> backup(Object? topics) => {
    'version': 1,
    'contacts': <Object>[],
    'conversations': [
      {'id': 'g', 'type': 'group', 'unreadCount': 0},
    ],
    'messages': <Object>[],
    'groupTopics': ?topics,
  };

  const topic = StoredGroupTopic(
    topic: 'Plan the trip',
    version: 7,
    setBy: 'alice',
  );

  test('a backup carries the topic and a restore brings it back', () async {
    final source = newDb();
    await group(source, 'g');
    await writeGroupTopicIfNewer(source, 'g', topic);
    // A pending topic send is a transient row: never in the backup.
    await source
        .into(source.messages)
        .insert(
          MessagesCompanion.insert(
            id: 'ctl',
            conversationId: 'g',
            senderId: 'me',
            type: const Value('group-topic'),
            status: const Value('sending'),
            createdAt: DateTime.utc(2026),
          ),
        );

    final data = await buildBackupData(source);
    expect(data['groupTopics'], [
      {
        'conversationId': 'g',
        'topic': 'Plan the trip',
        'version': 7,
        'setBy': 'alice',
      },
    ]);
    expect(data['messages'], isEmpty);

    final target = newDb();
    await importBackup(target, jsonDecode(jsonEncode(data)));
    final restored = await readGroupTopic(target, 'g');
    expect(restored?.topic, 'Plan the trip');
    expect(restored?.version, 7);
    expect(restored?.setBy, 'alice');
  });

  test('history transfer leaves out topics of excluded chats', () async {
    final source = newDb();
    await group(source, 'g');
    await writeGroupTopicIfNewer(source, 'g', topic);
    final data = await buildBackupData(source, withMessages: (_) => false);
    expect(data['groupTopics'], isEmpty);
  });

  test('an older backup without the key restores as before', () async {
    final target = newDb();
    await importBackup(target, backup(null));
    expect(await readGroupTopic(target, 'g'), isNull);
  });

  test('bad rows are skipped, not an error', () async {
    final target = newDb();
    await importBackup(
      target,
      backup([
        {'conversationId': 'g', 'topic': 'x', 'version': 0, 'setBy': 'a'},
        {'conversationId': 'g', 'topic': 5, 'version': 3, 'setBy': 'a'},
        {
          'conversationId': 'g',
          'topic': 'x' * 4001,
          'version': 3,
          'setBy': 'a',
        },
        {'conversationId': 'other', 'topic': 'x', 'version': 3, 'setBy': 'a'},
        'junk',
        {'conversationId': 'g', 'topic': 'ok', 'version': 3, 'setBy': 'a'},
      ]),
    );
    expect((await readGroupTopic(target, 'g'))?.topic, 'ok');
    expect(await readGroupTopic(target, 'other'), isNull);
  });

  test('a newer topic already on this device is kept', () async {
    final target = newDb();
    await group(target, 'g');
    await writeGroupTopicIfNewer(
      target,
      'g',
      const StoredGroupTopic(topic: 'newer', version: 9, setBy: 'alice'),
    );
    await importBackup(
      target,
      backup([
        {'conversationId': 'g', ...topic.toJson()},
      ]),
    );
    expect((await readGroupTopic(target, 'g'))?.topic, 'newer');
  });
}
