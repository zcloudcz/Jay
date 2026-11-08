import 'dart:convert';

import 'package:calltype_protocol/crypto/key_manager.dart';
import 'package:calltype_protocol/store/memory_protocol_store.dart';
import 'package:calltype_protocol/crypto/session_manager.dart';

import 'session_vector_scenario.dart' show StateReader;

/// Vector device without any database.
Future<({SessionManager sessions, StateReader readState})> memoryVectorDevice(
  KeyManager keys,
) async {
  final store = MemoryProtocolStore();
  Future<Map<String, dynamic>?> read(String address) async {
    final data = await store.loadSession(address);
    if (data == null) return null;
    return jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
  }

  return (
    sessions: SessionManager(store: store, keyManager: keys),
    readState: read,
  );
}
