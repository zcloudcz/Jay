/// Small key-value store for secrets (identity keys, device credential).
///
/// WHY an abstract class here: [KeyManager] and [AuthService] only ever need
/// string read/write/delete, but the app's real backend is
/// flutter_secure_storage (Keychain/Keystore), which drags in the Flutter SDK.
/// Keeping just this seam in the core lets a headless bot plug in its own
/// backend (e.g. an encrypted file) while the app keeps using the keychain.
///
/// The device-identity helpers live here, not in the app, because the
/// 'ct_device_id' / 'ct_device_secret' key names are shared protocol state:
/// [AuthService] reads exactly what registration wrote.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);

  static const _keyDeviceId = 'ct_device_id';
  static const _keyDeviceSecret = 'ct_device_secret';

  /// Retrieves the persisted device UUID, or null if the device has
  /// not been provisioned yet.
  Future<String?> getDeviceId() => read(_keyDeviceId);

  /// Persists the device UUID after initial provisioning. Called once
  /// during first launch after the server assigns the device ID.
  Future<void> setDeviceId(String id) => write(_keyDeviceId, id);

  /// Retrieves the device secret issued by the server at registration,
  /// or null if the device has not been provisioned yet.
  ///
  /// This is the device's API credential: it is exchanged for short-lived
  /// JWTs via POST /auth/token. The server only stores its hash, so this
  /// copy is the only one in existence — losing it means re-registering.
  Future<String?> getDeviceSecret() => read(_keyDeviceSecret);

  /// Persists the device secret. Called once during registration — the
  /// server returns the secret exactly once and never again.
  Future<void> setDeviceSecret(String secret) =>
      write(_keyDeviceSecret, secret);
}
