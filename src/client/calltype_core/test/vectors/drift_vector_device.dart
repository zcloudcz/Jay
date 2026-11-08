import 'dart:convert';

import 'package:calltype_core/crypto/key_manager.dart';
import 'package:calltype_core/crypto/session_manager.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:calltype_core/storage/drift_protocol_store.dart';
import 'package:drift/native.dart';

import 'vector_scenario.dart' show StateReader;

/// Vector device over the app's real drift schema (in-memory SQLite).
Future<({SessionManager sessions, StateReader readState})> driftVectorDevice(
  KeyManager keys,
) async {
  final db = AppDatabase(NativeDatabase.memory());
  Future<Map<String, dynamic>?> read(String address) async {
    final row = await (db.select(
      db.signalSessions,
    )..where((s) => s.address.equals(address))).getSingleOrNull();
    if (row == null) return null;
    return jsonDecode(utf8.decode(row.sessionData)) as Map<String, dynamic>;
  }

  return (
    sessions: SessionManager(store: DriftProtocolStore(db), keyManager: keys),
    readState: read,
  );
}
