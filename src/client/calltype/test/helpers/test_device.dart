import 'package:drift/native.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/devices/device_directory.dart';
import 'package:calltype_core/crypto/key_manager.dart';
import 'package:calltype_core/crypto/session_manager.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:calltype/core/storage/secure_storage.dart';

/// A complete simulated device for crypto/messaging tests: in-memory DB,
/// in-memory secure storage, real KeyManager and SessionManager.
///
/// Shared between session-manager and inbox tests so both exercise the
/// exact same key generation and session flows a real device performs.
class TestDevice {
  TestDevice._(this.id, this.db, this.secureStorage, this.keys, this.sessions);

  final String id;
  final AppDatabase db;
  final SecureStorage secureStorage;
  final KeyManager keys;
  final SessionManager sessions;

  /// This device's view of device lists. Its API answers "no list" for
  /// everybody, which is the single-device world most tests live in (and
  /// avoids a DNS lookup of the dummy base URL); tests that need lists build
  /// a directory against FakeMultiDeviceServer instead.
  late final DeviceDirectory directory = DeviceDirectory(
    database: db,
    apiClient: NoDeviceListsApi(),
    selfDeviceId: id,
    selfSigningKey: () async =>
        (await keys.getSignedIdentityBundle())['signingKey']!,
    selfIdentityKey: keys.getPublicIdentityKey,
  );

  static Future<TestDevice> create(String id) =>
      createWithSecureStorage(id, InMemorySecureStorage());

  /// Variant reusing existing secure storage — simulates an app reinstall
  /// where the keychain survives but the database does not.
  static Future<TestDevice> createWithSecureStorage(
    String id,
    SecureStorage secureStorage,
  ) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final keys = KeyManager(secureStorage: secureStorage);
    final sessions = SessionManager(database: db, keyManager: keys);
    final device = TestDevice._(id, db, secureStorage, keys, sessions);
    // Pre-generate all key material, as onboarding does on a real device.
    await keys.getOrCreateIdentityKeyPair();
    await keys.getOrCreateSignedPreKey();
    await keys.getOrCreateOneTimePreKeys();
    return device;
  }

  var _servedOneTimeKeys = 0;

  /// Builds the key bundle the server would serve for this device,
  /// consuming one one-time pre-key like the real endpoint does.
  Future<Map<String, dynamic>> keyBundle({bool includeOneTime = true}) async {
    final identityKey = await keys.getPublicIdentityKey();
    final signedPreKey = await keys.getOrCreateSignedPreKey();

    Map<String, dynamic>? oneTime;
    if (includeOneTime) {
      final all = await keys.getOrCreateOneTimePreKeys();
      // A different key per fetch, like the server: two initiators that got
      // the same one would break the second one's first message, because the
      // receiver deletes the private half when the first one arrives.
      final next = all[_servedOneTimeKeys++ % all.length];
      oneTime = {'keyId': next['keyId'], 'publicKey': next['publicKey']};
    }

    return {
      ...await keys.getSignedIdentityBundle(),
      'identityKey': identityKey,
      'signedPreKey': signedPreKey['publicKey'],
      'oneTimePreKey': ?oneTime,
    };
  }

  Future<void> close() async {
    await db.close();
  }
}

/// In-memory SecureStorage — KeyManager's only dependency. The real one
/// uses platform channels (Keychain/Keystore) which don't exist in unit
/// tests; a plain map preserves the same read/write/delete semantics.
class InMemorySecureStorage extends SecureStorage {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}

/// An API with no device lists at all.
class NoDeviceListsApi extends ApiClient {
  NoDeviceListsApi() : super(baseUrl: 'http://unused');
  @override
  Future<Map<String, dynamic>?> getDeviceList(String deviceId) async => null;
}
