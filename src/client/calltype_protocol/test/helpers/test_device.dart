import 'package:calltype_protocol/crypto/key_manager.dart';
import 'package:calltype_protocol/crypto/session_manager.dart';
import 'package:calltype_protocol/store/memory_protocol_store.dart';
import 'package:calltype_protocol/store/secret_store.dart';

/// A complete simulated device for protocol tests: in-memory protocol
/// store, in-memory secret store, real KeyManager and SessionManager. No
/// database: calltype_core runs the same flows over its drift store.
class TestDevice {
  TestDevice._(
    this.id,
    this.store,
    this.secureStorage,
    this.keys,
    this.sessions,
  );

  final String id;
  final MemoryProtocolStore store;
  final SecretStore secureStorage;
  final KeyManager keys;
  final SessionManager sessions;

  static Future<TestDevice> create(String id) =>
      createWithSecureStorage(id, InMemorySecureStorage());

  /// Variant reusing existing secure storage: simulates an app reinstall
  /// where the keychain survives but the database does not.
  static Future<TestDevice> createWithSecureStorage(
    String id,
    SecretStore secureStorage,
  ) async {
    final store = MemoryProtocolStore();
    final keys = KeyManager(secureStorage: secureStorage);
    final sessions = SessionManager(store: store, keyManager: keys);
    final device = TestDevice._(id, store, secureStorage, keys, sessions);
    // Pre-generate all key material, as onboarding does on a real device.
    await keys.getOrCreateIdentityKeyPair();
    await keys.getOrCreateSignedPreKey();
    await keys.getOrCreateOneTimePreKeys();
    return device;
  }

  /// Builds the key bundle the server would serve for this device,
  /// consuming one one-time pre-key like the real endpoint does.
  Future<Map<String, dynamic>> keyBundle({bool includeOneTime = true}) async {
    final identityKey = await keys.getPublicIdentityKey();
    final signedPreKey = await keys.getOrCreateSignedPreKey();

    Map<String, dynamic>? oneTime;
    if (includeOneTime) {
      final all = await keys.getOrCreateOneTimePreKeys();
      final first = all.first;
      oneTime = {'keyId': first['keyId'], 'publicKey': first['publicKey']};
    }

    return {
      ...await keys.getSignedIdentityBundle(),
      'identityKey': identityKey,
      'signedPreKey': signedPreKey['publicKey'],
      'oneTimePreKey': ?oneTime,
    };
  }

  Future<void> close() async {}
}

/// In-memory SecretStore: KeyManager's only dependency. A plain map with
/// the same read/write/delete semantics as the platform keychain.
class InMemorySecureStorage extends SecretStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}
