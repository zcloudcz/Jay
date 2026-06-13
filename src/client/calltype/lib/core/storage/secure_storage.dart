import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Wrapper around platform-secure key-value storage (Keychain on iOS,
/// EncryptedSharedPreferences on Android, libsecret on Linux).
///
/// Stores small, sensitive values that must not live in the regular
/// SQLite database: the database encryption key, device identity,
/// and user PIN hash. For larger structured data use [AppDatabase].
///
/// All keys are prefixed with 'zm_' to avoid collisions if the
/// secure storage namespace is shared with other Flutter plugins.
class SecureStorage {
  SecureStorage({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  // -- Key constants -------------------------------------------------------

  static const _keyDbKey = 'zm_db_key';
  static const _keyDeviceId = 'zm_device_id';
  static const _keyDeviceSecret = 'zm_device_secret';
  static const _keyPinHash = 'zm_pin_hash';

  // -- Database encryption key ---------------------------------------------

  /// Returns the 32-byte database encryption key, generating and
  /// persisting a new one on first call.
  ///
  /// The key is stored as a base64 string in the platform keychain.
  /// Once created it must never change — doing so would make the
  /// encrypted database unreadable.
  Future<List<int>> getOrCreateDbKey() async {
    final existing = await _storage.read(key: _keyDbKey);
    if (existing != null) {
      return base64Decode(existing);
    }

    // Cryptographically secure random 32-byte key.
    final rng = Random.secure();
    final key = List<int>.generate(32, (_) => rng.nextInt(256));

    await _storage.write(key: _keyDbKey, value: base64Encode(key));
    return key;
  }

  // -- Device identity -----------------------------------------------------

  /// Retrieves the persisted device UUID, or null if the device has
  /// not been provisioned yet.
  Future<String?> getDeviceId() => _storage.read(key: _keyDeviceId);

  /// Persists the device UUID after initial provisioning. Called once
  /// during first launch after the server assigns the device ID.
  Future<void> setDeviceId(String id) =>
      _storage.write(key: _keyDeviceId, value: id);

  /// Retrieves the device secret issued by the server at registration,
  /// or null if the device has not been provisioned yet.
  ///
  /// This is the device's API credential: it is exchanged for short-lived
  /// JWTs via POST /auth/token. The server only stores its hash, so this
  /// copy is the only one in existence — losing it means re-registering.
  Future<String?> getDeviceSecret() => _storage.read(key: _keyDeviceSecret);

  /// Persists the device secret. Called once during registration — the
  /// server returns the secret exactly once and never again.
  Future<void> setDeviceSecret(String secret) =>
      _storage.write(key: _keyDeviceSecret, value: secret);

  // -- PIN / biometric lock ------------------------------------------------

  /// Retrieves the stored PIN hash, or null if no PIN is set.
  /// The hash is computed client-side (e.g. SHA-256) before storage
  /// so the raw PIN never touches disk.
  Future<String?> getPinHash() => _storage.read(key: _keyPinHash);

  /// Stores a new PIN hash, overwriting any previous value.
  Future<void> setPinHash(String hash) =>
      _storage.write(key: _keyPinHash, value: hash);

  /// Removes the PIN hash, effectively disabling PIN lock.
  Future<void> deletePinHash() => _storage.delete(key: _keyPinHash);

  // -- Generic access ------------------------------------------------------

  /// Read an arbitrary key from secure storage.
  Future<String?> read(String key) => _storage.read(key: key);

  /// Write an arbitrary key-value pair to secure storage.
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  /// Delete an arbitrary key from secure storage.
  Future<void> delete(String key) => _storage.delete(key: key);
}
