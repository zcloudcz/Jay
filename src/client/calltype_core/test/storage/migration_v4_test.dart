import 'package:calltype_core/storage/database.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'schema_v3_fixture.dart';

/// v3 -> v4 (contracts §4) against a FROZEN copy of the v3 schema with data
/// in it — the migration must work on what is on users' devices, not on
/// whatever the current table classes happen to generate.
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory(setup: seedSchemaV3));
  });
  tearDown(() => db.close());

  test('keeps every v3 row and reports version 4', () async {
    final contacts = await (db.select(
      db.contacts,
    )..orderBy([(c) => OrderingTerm.asc(c.deviceId)])).get();
    expect(contacts.map((c) => c.userHandle), ['CT-ALIC-0001', 'CT-BOB0-0001']);
    expect(contacts.last.identityKey, [1, 2]);
    expect(contacts.last.isBot, isFalse);

    final messages = await (db.select(
      db.messages,
    )..orderBy([(m) => OrderingTerm.asc(m.id)])).get();
    expect(messages.map((m) => m.body), ['hello', 'hi back', '{"x":1}']);
    expect(messages[2].type, 'file');
    expect(messages[1].status, 'sent');

    final conversation = await db.select(db.conversations).getSingle();
    expect(conversation.unreadCount, 3);
    expect(conversation.organizationId, 'org-1');
    expect((await db.select(db.signalSessions).getSingle()).sessionData, [
      0xAA,
      0xBB,
    ]);
    expect((await db.select(db.backupState).getSingle()).key, 'outbox:m9');
    expect((await db.select(db.channels).getSingle()).name, 'News');
    expect((await db.select(db.channelPosts).getSingle()).body, 'post');
    expect((await db.select(db.blockedChannels).getSingle()).name, 'Spam');

    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 4);
  });

  test('data migration: no receipts for old history, verified carried over',
      () async {
    final messages = await (db.select(
      db.messages,
    )..orderBy([(m) => OrderingTerm.asc(m.id)])).get();
    // Every existing row counts as already answered with 'read' — otherwise
    // the first v4 start would send receipts for the whole history.
    expect(messages.map((m) => m.receiptSent), ['read', 'read', 'read']);
    // Incoming rows: read_at = received_at. Outgoing (no received_at): null.
    expect(messages[0].readAt, messages[0].receivedAt);
    expect(messages[0].readAt, isNotNull);
    expect(messages[1].readAt, isNull);
    // New content columns take their defaults.
    expect(messages.every((m) => m.forwarded == false), isTrue);
    expect(messages.every((m) => m.replyToId == null), isTrue);
    expect(messages.every((m) => m.mediaState == null), isTrue);

    final bob = await (db.select(
      db.contacts,
    )..where((c) => c.deviceId.equals('bob'))).getSingle();
    final alice = await (db.select(
      db.contacts,
    )..where((c) => c.deviceId.equals('alice'))).getSingle();
    expect(bob.verified, isTrue);
    expect(bob.verifiedAt, bob.addedAt);
    expect(alice.verified, isFalse);
    expect(alice.verifiedAt, isNull);
    expect(alice.identityKeyChangedAt, isNull);
    expect(alice.deviceListVersion, isNull);

    final conversation = await db.select(db.conversations).getSingle();
    expect(conversation.mutedUntil, isNull);
    expect(conversation.draft, isNull);
    expect(conversation.leftAt, isNull);
  });

  test('migrated schema is identical to a fresh v4 install', () async {
    final fresh = AppDatabase(NativeDatabase.memory());
    addTearDown(fresh.close);
    expect(await _schema(db), await _schema(fresh));
  });

  test('every new v4 table is usable after the migration', () async {
    final now = DateTime.utc(2026, 9, 29, 12);
    await db
        .into(db.reactions)
        .insert(
          ReactionsCompanion.insert(
            messageId: 'm1',
            reactorId: 'bob',
            emoji: '👍',
            updatedAt: now,
          ),
        );
    await db
        .into(db.messageReceipts)
        .insert(
          MessageReceiptsCompanion.insert(messageId: 'm2', recipientId: 'bob'),
        );
    await db
        .into(db.messageRevisions)
        .insert(
          MessageRevisionsCompanion.insert(
            messageId: 'm2',
            revision: 0,
            body: 'hi back',
            editedAt: now,
          ),
        );
    await db
        .into(db.inboundLog)
        .insert(
          InboundLogCompanion.insert(
            senderId: 'bob',
            messageId: 'm1',
            processedAt: now,
          ),
        );
    await db
        .into(db.appSettings)
        .insert(
          AppSettingsCompanion.insert(
            key: 'privacy.readReceipts',
            value: 'true',
          ),
        );
    await db
        .into(db.attachmentTransfers)
        .insert(
          AttachmentTransfersCompanion.insert(
            messageId: 'm3',
            direction: 'up',
            totalBytes: 10,
            state: 'queued',
            updatedAt: now,
          ),
        );
    await db
        .into(db.peerProfiles)
        .insert(PeerProfilesCompanion.insert(deviceId: 'bob', updatedAt: now));
    await db
        .into(db.blockedDevices)
        .insert(
          BlockedDevicesCompanion.insert(deviceId: 'eve', blockedAt: now),
        );
    await db
        .into(db.contactDevices)
        .insert(
          ContactDevicesCompanion.insert(
            deviceId: 'bob-2',
            contactId: 'bob',
            addedAt: now,
          ),
        );
    await db
        .into(db.callLog)
        .insert(
          CallLogCompanion.insert(
            callId: 'c1',
            direction: 'incoming',
            outcome: 'missed',
            startedAt: now,
          ),
        );
    await (db.update(db.conversations)..where((c) => c.id.equals('bob')))
        .write(ConversationsCompanion(mutedUntil: Value(mutedForever)));

    expect((await db.select(db.reactions).getSingle()).emoji, '👍');
    expect(
      (await db.select(db.contactDevices).getSingle()).isPrimary,
      isFalse,
    );
    expect((await db.select(db.callLog).getSingle()).video, isFalse);
    // drift reads DateTimes back in local time; compare the instant.
    expect(
      (await db.select(db.conversations).getSingle()).mutedUntil!.toUtc(),
      mutedForever,
    );
  });
}

/// Normalized schema: every table's columns (name, type, not-null, default,
/// pk) plus the index names. Compares structure, not DDL text — ALTER TABLE
/// ADD COLUMN and CREATE TABLE spell the same column differently.
Future<Map<String, Object>> _schema(AppDatabase db) async {
  final tables = await db
      .customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name NOT LIKE 'sqlite_%' ORDER BY name",
      )
      .get();
  final result = <String, Object>{};
  for (final t in tables) {
    final name = t.read<String>('name');
    final columns = await db.customSelect("PRAGMA table_info('$name')").get();
    result[name] = {
      for (final c in columns)
        c.read<String>('name'): [
          c.read<String>('type'),
          c.read<int>('notnull'),
          c.readNullable<String>('dflt_value'),
          c.read<int>('pk'),
        ],
    };
  }
  final indexes = await db
      .customSelect(
        "SELECT name, tbl_name FROM sqlite_master WHERE type = 'index' "
        "AND name NOT LIKE 'sqlite_%' ORDER BY name",
      )
      .get();
  result['<indexes>'] = [
    for (final i in indexes)
      '${i.read<String>('tbl_name')}.${i.read<String>('name')}',
  ];
  return result;
}
