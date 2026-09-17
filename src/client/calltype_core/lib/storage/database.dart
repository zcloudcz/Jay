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
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// Kept as an alias of the default constructor so existing tests that
  /// inject an in-memory executor keep reading naturally.
  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 2;

  /// Schema history:
  ///   1 — contacts, conversations, messages, sessions, backup state
  ///   2 — contacts.is_bot + channels, channel_posts, blocked_channels
  ///       (bots and channels shipped together, hence ONE step)
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
    },
  );
}
