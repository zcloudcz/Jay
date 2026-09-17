import 'package:calltype_core/storage/database.dart';
import 'package:drift_flutter/drift_flutter.dart';

export 'package:calltype_core/storage/database.dart';

/// Opens the app database with a platform-appropriate backend.
///
/// The schema ([AppDatabase]) lives in the pure-Dart calltype_core package so
/// headless bots can share it; only this opener needs Flutter. [driftDatabase]
/// from drift_flutter picks the best SQLite backend per platform
/// (sqlite3_flutter_libs on mobile, sqlite3 WASM + drift worker on web).
///
/// [dbName] is the file name (without extension) used on disk.
AppDatabase openAppDatabase(String dbName) => AppDatabase(
  driftDatabase(
    name: dbName,
    web: DriftWebOptions(
      sqlite3Wasm: Uri.parse('sqlite3.wasm'),
      driftWorker: Uri.parse('drift_worker.js'),
    ),
  ),
);
