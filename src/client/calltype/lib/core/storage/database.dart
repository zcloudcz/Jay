import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'tables.dart';

part 'database.g.dart';

/// Central Drift database for the CallType client.
///
/// Aggregates all local tables: contacts, conversations, messages,
/// Signal Protocol sessions, and generic key-value backup state.
///
/// Uses [driftDatabase] from drift_flutter which picks the best
/// SQLite backend per platform (sqlite3_flutter_libs on mobile,
/// sql.js on web). SQLCipher encryption can be layered in later
/// by providing a custom [QueryExecutor] with an encryption key —
/// the table definitions stay the same.
@DriftDatabase(
  tables: [Contacts, Conversations, Messages, SignalSessions, BackupState],
)
class AppDatabase extends _$AppDatabase {
  /// Creates the database with a platform-appropriate backend.
  ///
  /// [dbName] is the file name (without extension) used on disk.
  /// Passing different names enables isolated test databases.
  AppDatabase(String dbName) : super(driftDatabase(name: dbName));

  /// Allows injecting a custom executor — useful for in-memory
  /// databases in tests or for adding SQLCipher encryption later.
  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 1;
}
