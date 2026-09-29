import 'package:calltype_core/storage/database.dart';
import 'package:drift/native.dart';
import 'package:test/test.dart';

/// Schema v1 exactly as shipped in the beta (the DDL drift generated for the
/// original five tables). Frozen here on purpose: the migration must keep
/// working against what is on users' devices, not against today's tables.
const _schemaV1 = [
  'CREATE TABLE contacts (device_id TEXT NOT NULL, user_handle TEXT NOT NULL, '
      'display_name TEXT NULL, identity_key BLOB NOT NULL, '
      'verified INTEGER NOT NULL DEFAULT 0 CHECK (verified IN (0, 1)), '
      'added_at INTEGER NOT NULL, PRIMARY KEY (device_id))',
  'CREATE TABLE conversations (id TEXT NOT NULL, type TEXT NOT NULL, '
      'title TEXT NULL, last_message_at INTEGER NULL, '
      'unread_count INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (id))',
  "CREATE TABLE messages (id TEXT NOT NULL, conversation_id TEXT NOT NULL, "
      "sender_id TEXT NOT NULL, body TEXT NULL, "
      "type TEXT NOT NULL DEFAULT 'text', attachment_path TEXT NULL, "
      "status TEXT NOT NULL DEFAULT 'sent', created_at INTEGER NOT NULL, "
      "received_at INTEGER NULL, PRIMARY KEY (id))",
  'CREATE TABLE signal_sessions (address TEXT NOT NULL, '
      'session_data BLOB NOT NULL, PRIMARY KEY (address))',
  'CREATE TABLE backup_state ("key" TEXT NOT NULL, value TEXT NOT NULL, '
      'PRIMARY KEY ("key"))',
];

void main() {
  test('v1 -> v4 keeps contacts, messages and sessions and adds bots + '
      'channels + organization columns', () async {
    final db = AppDatabase(
      NativeDatabase.memory(
        setup: (raw) {
          for (final ddl in _schemaV1) {
            raw.execute(ddl);
          }
          raw.execute(
            "INSERT INTO contacts (device_id, user_handle, identity_key, "
            "verified, added_at) VALUES ('bob', 'CT-BOB0-0001', x'0102', 1, "
            "1700000000)",
          );
          raw.execute(
            "INSERT INTO conversations (id, type, unread_count) "
            "VALUES ('bob', 'direct', 3)",
          );
          raw.execute(
            "INSERT INTO messages (id, conversation_id, sender_id, body, "
            "created_at) VALUES ('m1', 'bob', 'bob', 'hello', 1700000001)",
          );
          raw.execute(
            "INSERT INTO signal_sessions (address, session_data) "
            "VALUES ('bob.1', x'AABB')",
          );
          // Tells drift this is an existing v1 database → onUpgrade(1, 2).
          raw.execute('PRAGMA user_version = 1');
        },
      ),
    );
    addTearDown(db.close);

    // Existing data survives, the new column takes its default.
    final contact = await db.select(db.contacts).getSingle();
    expect(contact.userHandle, 'CT-BOB0-0001');
    expect(contact.identityKey, [1, 2]);
    expect(contact.verified, isTrue);
    expect(contact.isBot, isFalse);
    final message = await db.select(db.messages).getSingle();
    expect(message.body, 'hello');
    expect((await db.select(db.conversations).getSingle()).unreadCount, 3);
    expect((await db.select(db.signalSessions).getSingle()).sessionData, [
      0xAA,
      0xBB,
    ]);

    // New tables exist and are usable.
    await db
        .into(db.channels)
        .insert(
          ChannelsCompanion.insert(
            channelId: 'c1',
            handle: 'CH-AAAA-BBBB',
            name: 'News',
          ),
        );
    await db
        .into(db.channelPosts)
        .insert(
          ChannelPostsCompanion.insert(
            postId: 'p1',
            channelId: 'c1',
            kind: 'text',
            createdAt: '2026-09-17T10:00:00.000Z',
          ),
        );
    await db
        .into(db.blockedChannels)
        .insert(
          BlockedChannelsCompanion.insert(
            channelId: 'c2',
            handle: 'CH-CCCC-DDDD',
            name: 'Spam',
            blockedAt: DateTime.now(),
          ),
        );
    expect(await db.select(db.channels).get(), hasLength(1));
    expect(await db.select(db.channelPosts).get(), hasLength(1));
    expect(await db.select(db.blockedChannels).get(), hasLength(1));

    // v3 (Jay Business mode) columns take their null default on an existing
    // (anonymous) conversation.
    final conversation = await db.select(db.conversations).getSingle();
    expect(conversation.organizationId, isNull);
    expect(conversation.organizationName, isNull);

    final version = await db.customSelect('PRAGMA user_version').getSingle();
    // Runs every step up to the current version (v4 included).
    expect(version.read<int>('user_version'), 4);
  });

  test('a fresh install creates the v2 schema directly', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    expect(await db.select(db.channels).get(), isEmpty);
    expect(await db.select(db.contacts).get(), isEmpty);
  });
}
