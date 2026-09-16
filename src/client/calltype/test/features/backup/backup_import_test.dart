import 'dart:typed_data';
import 'package:calltype/core/storage/database.dart';
import 'package:calltype/features/backup/backup_import.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> fixture() => {
  'version': 1,
  'contacts': [
    {
      'deviceId': 'peer',
      'userHandle': 'CT-PEER',
      'displayName': 'Old',
      'identityKey': 'AQID',
      'verified': true,
      'addedAt': '2026-01-01T00:00:00Z',
    },
  ],
  'conversations': [
    {
      'id': 'chat',
      'type': 'direct',
      'title': null,
      'lastMessageAt': null,
      'unreadCount': 0,
    },
  ],
  'messages': [
    {
      'id': 'message',
      'conversationId': 'chat',
      'senderId': 'peer',
      'body': 'restored text',
      'type': 'text',
      'status': 'read',
      'createdAt': '2026-01-01T00:00:00Z',
      'receivedAt': null,
    },
  ],
};
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());
  test(
    'unverified contact without a fetched key survives backup restore',
    () async {
      final data = fixture();
      (data['contacts'] as List).single['identityKey'] = '';
      (data['contacts'] as List).single['verified'] = false;
      await importBackup(db, data);
      expect((await db.select(db.contacts).get()).single.identityKey, isEmpty);
    },
  );
  test(
    'restore preserves current contact key and message while merging missing rows',
    () async {
      await db
          .into(db.contacts)
          .insert(
            ContactsCompanion.insert(
              deviceId: 'peer',
              userHandle: 'CT-CURRENT',
              identityKey: Uint8List.fromList([9]),
              addedAt: DateTime(2026),
            ),
          );
      await importBackup(db, fixture());
      await importBackup(db, fixture());
      expect((await db.select(db.contacts).get()).single.identityKey, [9]);
      expect((await db.select(db.messages).get()).single.body, 'restored text');
    },
  );
  test(
    'invalid message reference rejects the whole backup before inserting contacts',
    () async {
      final data = fixture();
      (data['messages'] as List).single['conversationId'] = 'missing';
      await expectLater(importBackup(db, data), throwsFormatException);
      expect(await db.select(db.contacts).get(), isEmpty);
    },
  );
  test('new restored contact needs fresh verification', () async {
    await importBackup(db, fixture());
    expect((await db.select(db.contacts).get()).single.verified, false);
  });
}
