import 'dart:convert';
import 'dart:math';

import 'package:calltype_core/storage/secret_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Wrapper around platform-secure key-value storage (Keychain on iOS,
/// EncryptedSharedPreferences on Android, libsecret on Linux).
///
/// Stores small, sensitive values that must not live in the regular
/// SQLite database: the database encryption key, device identity,
/// and user PIN hash. For larger structured data use [AppDatabase].
///
/// All keys are prefixed with 'ct_' to avoid collisions if the
/// secure storage namespace is shared with other Flutter plugins.
///
/// Extends the core's [SecretStore] so the pure-Dart KeyManager/AuthService
/// (package calltype_core) can use the keychain without knowing Flutter. The
/// device id/secret accessors are inherited from there.
class SecureStorage extends SecretStore {
  SecureStorage({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  // -- Key constants -------------------------------------------------------

  static const _keyDbKey = 'ct_db_key';
  static const _keyPinHash = 'ct_pin_hash';

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

  Future<String?> getAccountId() => _storage.read(key: 'ct_account_id');

  Future<void> setAccountId(String id) =>
      _storage.write(key: 'ct_account_id', value: id);

  // -- Generic access ------------------------------------------------------

  /// Read an arbitrary key from secure storage.
  @override
  Future<String?> read(String key) => _storage.read(key: key);

  /// Write an arbitrary key-value pair to secure storage.
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  /// Delete an arbitrary key from secure storage.
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
