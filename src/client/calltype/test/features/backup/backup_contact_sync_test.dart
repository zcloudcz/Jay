import 'dart:convert';

import 'package:calltype_core/storage/database.dart';
import 'package:calltype/features/backup/backup_controller.dart';
import 'package:calltype/features/backup/backup_import.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Contacts in the backup gain `nameChangedAt` (and `isBot`) for contact
/// sync (spec 2026-11-08-contact-sync); the history transfer reuses the
/// same writer and imports with the sync rule for names.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  const bob = 'b0000000-0000-4000-8000-000000000001';

  Future<AppDatabase> withBob(String? name, int at, {bool bot = false}) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db
        .into(db.contacts)
        .insert(
          ContactsCompanion.insert(
            deviceId: bob,
            userHandle: 'CT-BOB0-0001',
            displayName: Value(name),
            identityKey: Uint8List.fromList([1, 2]),
            addedAt: DateTime.utc(2026, 10, 1),
            isBot: Value(bot),
            nameChangedAt: Value(at),
          ),
        );
    return db;
  }

  Future<Contact> bobIn(AppDatabase db) => (db.select(
    db.contacts,
  )..where((c) => c.deviceId.equals(bob))).getSingle();

  test(
    'a backup carries nameChangedAt and isBot; a restore keeps them',
    () async {
      final source = await withBob('Bob', 1234, bot: true);
      final data = await buildBackupData(source);
      final contact = (data['contacts'] as List).single as Map;
      expect(contact['nameChangedAt'], 1234);
      expect(contact['isBot'], isTrue);

      final target = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(target.close);
      await importBackup(target, jsonDecode(jsonEncode(data)));
      final restored = await bobIn(target);
      expect(restored.nameChangedAt, 1234);
      expect(restored.isBot, isTrue);
    },
  );

  test('an older backup without the keys restores with 0 and false', () async {
    final target = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(target.close);
    await importBackup(target, {
      'version': 1,
      'contacts': [
        {
          'deviceId': bob,
          'userHandle': 'CT-BOB0-0001',
          'displayName': 'Bob',
          'identityKey': base64Encode([1]),
          'verified': true,
          'addedAt': '2026-10-01T00:00:00.000Z',
        },
      ],
      'conversations': [],
      'messages': [],
    });
    final restored = await bobIn(target);
    expect(restored.nameChangedAt, 0);
    expect(restored.isBot, isFalse);
    expect(restored.verified, isFalse);
  });

  test(
    'a restore keeps the local name; a merge lets the newer name win',
    () async {
      final archive = await buildBackupData(await withBob('Archive', 2000));

      final restored = await withBob('Local', 1000);
      await importBackup(restored, jsonDecode(jsonEncode(archive)));
      expect((await bobIn(restored)).displayName, 'Local');

      final merged = await withBob('Local', 1000);
      await importBackup(
        merged,
        jsonDecode(jsonEncode(archive)),
        mergeContacts: true,
      );
      expect((await bobIn(merged)).displayName, 'Archive');
      expect((await bobIn(merged)).nameChangedAt, 2000);

      final newer = await withBob('Newer', 3000);
      await importBackup(
        newer,
        jsonDecode(jsonEncode(archive)),
        mergeContacts: true,
      );
      expect((await bobIn(newer)).displayName, 'Newer');
    },
  );

  test(
    'history transfer leaves out messages of rejected conversations',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await db
          .into(db.conversations)
          .insert(ConversationsCompanion.insert(id: 'a', type: 'direct'));
      await db
          .into(db.conversations)
          .insert(
            ConversationsCompanion.insert(
              id: 'biz',
              type: 'group',
              organizationId: const Value('org'),
              organizationName: const Value('Acme'),
            ),
          );
      for (final (id, chat) in [('m1', 'a'), ('m2', 'biz')]) {
        await db
            .into(db.messages)
            .insert(
              MessagesCompanion.insert(
                id: id,
                conversationId: chat,
                senderId: 'x',
                body: const Value('hi'),
                createdAt: DateTime.utc(2026),
              ),
            );
      }
      final data = await buildBackupData(
        db,
        withMessages: (c) => c.organizationId == null,
      );
      expect(
        [for (final m in data['messages'] as List) (m as Map)['id']],
        ['m1'],
      );
      // The header stays, with its organization.
      final biz = (data['conversations'] as List).cast<Map>().firstWhere(
        (c) => c['id'] == 'biz',
      );
      expect(biz['organizationName'], 'Acme');
    },
  );
}
