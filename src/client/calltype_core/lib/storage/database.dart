import 'package:drift/drift.dart';

import 'tables.dart';

part 'database.g.dart';

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
    KnownDeviceLists,
    KnownDeviceListMembers,
    MessageReactions,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// Kept as an alias of the default constructor so existing tests that
  /// inject an in-memory executor keep reading naturally.
  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 8;

  /// Schema history:
  ///   1 — contacts, conversations, messages, sessions, backup state
  ///   2 — contacts.is_bot + channels, channel_posts, blocked_channels
  ///       (bots and channels shipped together, hence ONE step)
  ///   3 — conversations.organization_id / organization_name (Jay Business
  ///       mode banner/badge, E05)
  ///   4 — messages.reply_to_id / reply_sender_id / reply_preview /
  ///       forwarded / deleted (reply, forward, delete for everyone)
  ///   5 - known_device_lists / known_device_list_members (multi-device:
  ///       verified signed device lists of contacts and of this identity)
  ///   6 - messages.edited_at / actions_json (agent messaging: edits and
  ///       bot buttons)
  ///   7 - channels.status / suspended_until, channel_posts.by_bot /
  ///       published_here (channel moderation and bot publishers)
  ///   8 - message_reactions (chat reactions)
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
      if (from < 4) {
        await m.addColumn(messages, messages.replyToId);
        await m.addColumn(messages, messages.replySenderId);
        await m.addColumn(messages, messages.replyPreview);
        await m.addColumn(messages, messages.forwarded);
        await m.addColumn(messages, messages.deleted);
      }
      if (from < 5) {
        await m.createTable(knownDeviceLists);
        await m.createTable(knownDeviceListMembers);
      }
      if (from < 6) {
        await m.addColumn(messages, messages.editedAt);
        await m.addColumn(messages, messages.actionsJson);
      }
      // WHY `from >= 2`: below v2 the channel tables were just created by
      // the step above with today's columns, so adding them again would fail
      // with "duplicate column".
      if (from < 7 && from >= 2) {
        await m.addColumn(channels, channels.status);
        await m.addColumn(channels, channels.suspendedUntil);
        await m.addColumn(channelPosts, channelPosts.byBot);
        await m.addColumn(channelPosts, channelPosts.publishedHere);
      }
      if (from < 8) {
        await m.createTable(messageReactions);
      }
    },
  );
}
