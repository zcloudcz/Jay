/// Schema v3 EXACTLY as drift generated it for the shipped beta (dumped from
/// `sqlite_master` of a fresh v3 database before the v4 change). Frozen on
/// purpose: migrations must keep working against what is on users' devices.
const schemaV3 = [
  'CREATE TABLE "contacts" ("device_id" TEXT NOT NULL, "user_handle" TEXT NOT '
      'NULL, "display_name" TEXT NULL, "identity_key" BLOB NOT NULL, '
      '"verified" INTEGER NOT NULL DEFAULT 0 CHECK ("verified" IN (0, 1)), '
      '"added_at" INTEGER NOT NULL, "is_bot" INTEGER NOT NULL DEFAULT 0 CHECK '
      '("is_bot" IN (0, 1)), PRIMARY KEY ("device_id"))',
  'CREATE TABLE "conversations" ("id" TEXT NOT NULL, "type" TEXT NOT NULL, '
      '"title" TEXT NULL, "last_message_at" INTEGER NULL, "unread_count" '
      'INTEGER NOT NULL DEFAULT 0, "organization_id" TEXT NULL, '
      '"organization_name" TEXT NULL, PRIMARY KEY ("id"))',
  'CREATE TABLE "messages" ("id" TEXT NOT NULL, "conversation_id" TEXT NOT '
      'NULL, "sender_id" TEXT NOT NULL, "body" TEXT NULL, "type" TEXT NOT NULL '
      "DEFAULT 'text', \"attachment_path\" TEXT NULL, \"status\" TEXT NOT NULL "
      "DEFAULT 'sent', \"created_at\" INTEGER NOT NULL, \"received_at\" "
      'INTEGER NULL, PRIMARY KEY ("id"))',
  'CREATE TABLE "signal_sessions" ("address" TEXT NOT NULL, "session_data" '
      'BLOB NOT NULL, PRIMARY KEY ("address"))',
  'CREATE TABLE "backup_state" ("key" TEXT NOT NULL, "value" TEXT NOT NULL, '
      'PRIMARY KEY ("key"))',
  'CREATE TABLE "channels" ("channel_id" TEXT NOT NULL, "handle" TEXT NOT '
      'NULL, "name" TEXT NOT NULL, "description" TEXT NOT NULL DEFAULT \'\', '
      '"follower_count" INTEGER NOT NULL DEFAULT 0, "role" TEXT NULL, '
      '"is_following" INTEGER NOT NULL DEFAULT 1 CHECK ("is_following" IN (0, '
      '1)), "unread_count" INTEGER NOT NULL DEFAULT 0, PRIMARY KEY '
      '("channel_id"))',
  'CREATE TABLE "channel_posts" ("post_id" TEXT NOT NULL, "channel_id" TEXT '
      'NOT NULL, "kind" TEXT NOT NULL, "body" TEXT NOT NULL DEFAULT \'\', '
      '"attachment_blob_path" TEXT NULL, "created_at" TEXT NOT NULL, '
      '"reactions" TEXT NOT NULL DEFAULT \'{}\', "my_reaction" TEXT NULL, '
      '"poll_votes" TEXT NOT NULL DEFAULT \'[]\', "my_vote" INTEGER NULL, '
      'PRIMARY KEY ("post_id"))',
  'CREATE TABLE "blocked_channels" ("channel_id" TEXT NOT NULL, "handle" TEXT '
      'NOT NULL, "name" TEXT NOT NULL, "blocked_at" INTEGER NOT NULL, PRIMARY '
      'KEY ("channel_id"))',
];

/// Representative v3 data: a verified and an unverified contact, a business
/// conversation with an incoming text, an outgoing text and an incoming
/// file, a ratchet session, an outbox entry and channel rows.
const dataV3 = [
  "INSERT INTO contacts (device_id, user_handle, identity_key, verified, "
      "added_at) VALUES ('bob', 'CT-BOB0-0001', x'0102', 1, 1700000000)",
  "INSERT INTO contacts (device_id, user_handle, identity_key, verified, "
      "added_at) VALUES ('alice', 'CT-ALIC-0001', x'0304', 0, 1700000005)",
  "INSERT INTO conversations (id, type, unread_count, organization_id, "
      "organization_name) VALUES ('bob', 'direct', 3, 'org-1', 'Acme')",
  "INSERT INTO messages (id, conversation_id, sender_id, body, status, "
      "created_at, received_at) VALUES ('m1', 'bob', 'bob', 'hello', "
      "'delivered', 1700000001, 1700000002)",
  "INSERT INTO messages (id, conversation_id, sender_id, body, status, "
      "created_at) VALUES ('m2', 'bob', 'me', 'hi back', 'sent', 1700000003)",
  "INSERT INTO messages (id, conversation_id, sender_id, body, type, status, "
      "created_at, received_at) VALUES ('m3', 'bob', 'bob', '{\"x\":1}', "
      "'file', 'delivered', 1700000004, 1700000005)",
  "INSERT INTO signal_sessions (address, session_data) VALUES ('bob', "
      "x'AABB')",
  "INSERT INTO backup_state (key, value) VALUES ('outbox:m9', '{}')",
  "INSERT INTO channels (channel_id, handle, name) VALUES ('c1', "
      "'CH-AAAA-BBBB', 'News')",
  "INSERT INTO channel_posts (post_id, channel_id, kind, body, created_at) "
      "VALUES ('p1', 'c1', 'text', 'post', '2026-09-17T10:00:00.000Z')",
  "INSERT INTO blocked_channels (channel_id, handle, name, blocked_at) VALUES "
      "('c2', 'CH-CCCC-DDDD', 'Spam', 1700000000)",
];

/// `NativeDatabase.memory(setup: seedSchemaV3)`: builds the v3 database and
/// sets `user_version = 3`, so drift runs `onUpgrade(3, 4)` when it opens.
/// Typed `dynamic` so calltype_core does not need a direct dependency on
/// package:sqlite3 just for this test helper.
void seedSchemaV3(dynamic raw) {
  for (final statement in [...schemaV3, ...dataV3]) {
    raw.execute(statement);
  }
  raw.execute('PRAGMA user_version = 3');
}
