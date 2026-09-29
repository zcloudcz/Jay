import 'package:drift/drift.dart';

import 'tables.dart';

part 'database.g.dart';

/// `Conversations.mutedUntil` value meaning "muted forever"
/// (`9999-12-31T00:00:00Z`, M §4.3). A far-future instant instead of a
/// separate flag keeps "is muted" a single comparison `mutedUntil > now`.
final mutedForever = DateTime.utc(9999, 12, 31);

/// Central Drift database for the CallType client.
///
/// Aggregates all local tables: contacts, conversations, messages,
/// Signal Protocol sessions, and generic key-value backup state.
///
/// WHY the executor is injected: drift itself is pure Dart, only *opening*
/// SQLite is platform-specific. The Flutter app passes the drift_flutter
/// executor (see `openAppDatabase` in the app's core/storage/database.dart),
/// a headless bot passes `NativeDatabase(File(...))`, tests pass
/// `NativeDatabase.memory()`. This was chosen over a separate SessionStore
/// interface because SessionManager's queries stay untouched and the bot and
/// the app share one schema and one migration path. SQLCipher encryption can
/// be layered in the same way — the table definitions stay the same.
@DriftDatabase(
  tables: [
    Contacts,
    Conversations,
    Messages,
    SignalSessions,
    BackupState,
    Channels,
    ChannelPosts,
    BlockedChannels,
    // v4 (gap closure, contracts §4)
    Reactions,
    MessageReceipts,
    MessageRevisions,
    InboundLog,
    AppSettings,
    AttachmentTransfers,
    PeerProfiles,
    BlockedDevices,
    ContactDevices,
    CallLog,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// Kept as an alias of the default constructor so existing tests that
  /// inject an in-memory executor keep reading naturally.
  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 4;

  /// Schema history:
  ///   1 — contacts, conversations, messages, sessions, backup state
  ///   2 — contacts.is_bot + channels, channel_posts, blocked_channels
  ///       (bots and channels shipped together, hence ONE step)
  ///   3 — conversations.organization_id / organization_name (Jay Business
  ///       mode banner/badge, E05)
  ///   4 — gap closure, ONE step for all streams (contracts §4): new columns
  ///       on messages (M, M2), conversations (M, G), contacts (S, G, D);
  ///       tables reactions, message_receipts, message_revisions,
  ///       inbound_log, app_settings (M), attachment_transfers (M2),
  ///       peer_profiles, blocked_devices (G), contact_devices (D),
  ///       call_log (C); index on messages(conversation_id, created_at).
  ///       One version instead of one per stream so parallel streams never
  ///       race for "the next schemaVersion".
  ///
  /// WHY explicit steps instead of destructive recreation: this database
  /// holds the user's only copy of their decrypted history and the ratchet
  /// sessions — losing it on an app update is not acceptable.
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.addColumn(contacts, contacts.isBot);
        await m.createTable(channels);
        await m.createTable(channelPosts);
        await m.createTable(blockedChannels);
      }
      if (from < 3) {
        await m.addColumn(conversations, conversations.organizationId);
        await m.addColumn(conversations, conversations.organizationName);
      }
      if (from < 4) await _migrateToV4(m);
    },
  );

  Future<void> _migrateToV4(Migrator m) async {
    // Every step is additive (nullable or defaulted columns, new tables), so
    // no existing row has to be rewritten except by the data fix-ups below.
    for (final column in <GeneratedColumn>[
      messages.replyToId,
      messages.replyToSenderId,
      messages.replyPreview,
      messages.forwarded,
      messages.editedAt,
      messages.deletedAt,
      messages.readAt,
      messages.receiptSent,
      messages.expiresAt,
      messages.mediaBlobId,
      messages.mediaState,
    ]) {
      await m.addColumn(messages, column);
    }
    for (final column in <GeneratedColumn>[
      conversations.mutedUntil,
      conversations.draft,
      conversations.pinnedAt,
      conversations.archivedAt,
      conversations.leftAt,
      conversations.titleUpdatedAt,
    ]) {
      await m.addColumn(conversations, column);
    }
    for (final column in <GeneratedColumn>[
      contacts.verifiedAt,
      contacts.identityKeyChangedAt,
      contacts.deviceListVersion,
      contacts.deviceListRoot,
    ]) {
      await m.addColumn(contacts, column);
    }
    for (final table in <TableInfo>[
      reactions,
      messageReceipts,
      messageRevisions,
      inboundLog,
      appSettings,
      attachmentTransfers,
      peerProfiles,
      blockedDevices,
      contactDevices,
      callLog,
    ]) {
      await m.createTable(table);
    }
    // createTable does not create the table's indexes — only createAll does.
    await m.createIndex(idxMessagesConversationCreated);
    await m.createIndex(contactDevicesContact);
    await m.createIndex(callLogStartedAt);
    await m.createIndex(callLogConversation);

    // MANDATORY data migration (contracts §4). Without it the first v4 start
    // would treat the whole existing history as "never acknowledged" and
    // send delivered/read receipts for every message ever received.
    await customStatement("UPDATE messages SET receipt_sent = 'read'");
    await customStatement(
      'UPDATE messages SET read_at = received_at WHERE received_at IS NOT NULL',
    );
    // The boolean was the only verification record so far; carry it over
    // with the best timestamp we have (G §4.1 — zero rows today, but a
    // verified contact must not silently become "unverified").
    await customStatement(
      'UPDATE contacts SET verified_at = added_at WHERE verified = 1',
    );
  }
}
