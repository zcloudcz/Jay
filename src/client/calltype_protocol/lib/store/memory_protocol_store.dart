import 'dart:async';
import 'dart:typed_data';

import 'protocol_store.dart';

/// In-memory [ProtocolStore] for tests and tools: no database, same
/// semantics as the drift store.
///
/// [transaction] snapshots the state and restores it when the action
/// throws, so tests can prove that a crash in the middle of processing
/// leaves the ratchet where it was. Nested calls join the outer transaction
/// (like drift, through a zone value); outer transactions run one at a time.
class MemoryProtocolStore implements ProtocolStore {
  final _sessions = <String, Uint8List>{};
  final _pins = <String, String>{};
  final _contactKeys = <String, Uint8List>{};
  final _consumed = <int, String>{};

  static final _zoneKey = Object();
  Future<void> _tail = Future.value();

  /// Adds a contact entry (optionally with a known identity key), like the
  /// app's contacts table. Pinning only updates existing contacts.
  void addContact(String peerDeviceId, [Uint8List? identityKey]) =>
      _contactKeys[peerDeviceId] = identityKey ?? Uint8List(0);

  /// Every stored session address, for assertions in tests.
  Iterable<String> get sessionAddresses => _sessions.keys;

  @override
  Future<T> transaction<T>(Future<T> Function() action) async {
    if (Zone.current[_zoneKey] == this) return action();
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    await previous;
    final sessions = Map.of(_sessions);
    final pins = Map.of(_pins);
    final contacts = Map.of(_contactKeys);
    final consumed = Map.of(_consumed);
    try {
      return await runZoned(action, zoneValues: {_zoneKey: this});
    } catch (_) {
      _restore(_sessions, sessions);
      _restore(_pins, pins);
      _restore(_contactKeys, contacts);
      _restore(_consumed, consumed);
      rethrow;
    } finally {
      done.complete();
    }
  }

  static void _restore<K, V>(Map<K, V> target, Map<K, V> snapshot) {
    target
      ..clear()
      ..addAll(snapshot);
  }

  @override
  Future<Uint8List?> loadSession(String address) async => _sessions[address];

  @override
  Future<void> saveSession(String address, Uint8List data) async =>
      _sessions[address] = Uint8List.fromList(data);

  @override
  Future<List<({String address, Uint8List data})>> listSessions(
    String prefix,
  ) async {
    // Same matching as the drift store's LIKE: ASCII case-insensitive.
    final lower = prefix.toLowerCase();
    return [
      for (final e in _sessions.entries)
        if (e.key.toLowerCase().startsWith(lower))
          (address: e.key, data: e.value),
    ];
  }

  @override
  Future<void> deleteSessions(List<String> addresses) async {
    for (final a in addresses) {
      _sessions.remove(a);
    }
  }

  @override
  Future<String?> pinnedIdentity(String peerDeviceId) async =>
      _pins[peerDeviceId];

  @override
  Future<void> pinIdentity(String peerDeviceId, String fingerprint) async =>
      _pins[peerDeviceId] = fingerprint;

  @override
  Future<Uint8List?> contactIdentityKey(String peerDeviceId) async =>
      _contactKeys[peerDeviceId];

  @override
  Future<void> setContactIdentityKey(
    String peerDeviceId,
    Uint8List identityKey,
  ) async {
    if (_contactKeys.containsKey(peerDeviceId)) {
      _contactKeys[peerDeviceId] = Uint8List.fromList(identityKey);
    }
  }

  @override
  Future<bool> isPreKeyConsumed(int keyId) async =>
      _consumed.containsKey(keyId);

  @override
  Future<void> markPreKeyConsumed(int keyId, String peerDeviceId) async =>
      _consumed[keyId] = peerDeviceId;

  @override
  Future<List<int>> consumedPreKeyIds() async => _consumed.keys.toList();
}
