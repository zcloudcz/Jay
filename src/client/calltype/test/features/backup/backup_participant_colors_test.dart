import 'dart:convert';

import 'package:calltype/features/backup/backup_controller.dart';
import 'package:calltype/features/backup/backup_import.dart';
import 'package:calltype/features/chat/participant_colors.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Backup / history transfer carry the participant color choices (spec
/// 2026-11-09-participant-colors D10).
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  AppDatabase newDb() {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    return db;
  }

  Map<String, dynamic> emptyBackup([Object? colors]) => {
    'version': 1,
    'contacts': <Object>[],
    'conversations': <Object>[],
    'messages': <Object>[],
    'participantColors': ?colors,
  };

  Future<Map<String, String>> colorRows(AppDatabase db) async => {
    for (final r in await db.select(db.backupState).get())
      if (r.key.startsWith(participantColorKeyPrefix)) r.key: r.value,
  };

  test('a backup carries the choices and a restore brings them back', () async {
    final source = newDb();
    final store = ParticipantColors(database: source);
    addTearDown(store.dispose);
    await store.setChoice('CT-BOB0-0001', 4);
    await store.setChoice('b0000000-0000-4000-8000-000000000009', 0);
    await source
        .into(source.backupState)
        .insert(
          BackupStateCompanion.insert(key: 'bot_notice_seen:x', value: '1'),
        );

    final data = await buildBackupData(source);
    expect(
      data['participantColors'],
      unorderedEquals([
        {'key': 'CT-BOB0-0001', 'color': 4},
        {'key': 'b0000000-0000-4000-8000-000000000009', 'color': 0},
      ]),
    );

    final target = newDb();
    await importBackup(target, jsonDecode(jsonEncode(data)));
    expect(await colorRows(target), {
      'participant_color:CT-BOB0-0001': '4',
      'participant_color:b0000000-0000-4000-8000-000000000009': '0',
    });
    final restored = ParticipantColors(database: target);
    addTearDown(restored.dispose);
    await restored.load();
    expect(restored.indexFor('CT-BOB0-0001'), 4);
  });

  test('an older backup without the key restores as before', () async {
    final target = newDb();
    await importBackup(target, emptyBackup());
    expect(await colorRows(target), isEmpty);
  });

  test('bad rows are skipped, not an error', () async {
    final target = newDb();
    await importBackup(
      target,
      emptyBackup([
        {'key': 'CT-AAAA-0001', 'color': 10},
        {'key': 'CT-AAAA-0002', 'color': -1},
        {'key': 'CT-AAAA-0003', 'color': '2'},
        {'key': '', 'color': 1},
        {'color': 1},
        'junk',
        {'key': 'ct-aaaa-0004', 'color': 7},
      ]),
    );
    expect(await colorRows(target), {'participant_color:CT-AAAA-0004': '7'});
  });

  test('a non-list value is ignored', () async {
    final target = newDb();
    await importBackup(target, emptyBackup('nope'));
    expect(await colorRows(target), isEmpty);
  });

  test('a choice already on this device is kept', () async {
    final target = newDb();
    final store = ParticipantColors(database: target);
    addTearDown(store.dispose);
    await store.setChoice('CT-BOB0-0001', 2);
    await importBackup(
      target,
      emptyBackup([
        {'key': 'CT-BOB0-0001', 'color': 5},
      ]),
    );
    expect(await colorRows(target), {'participant_color:CT-BOB0-0001': '2'});
  });
}
