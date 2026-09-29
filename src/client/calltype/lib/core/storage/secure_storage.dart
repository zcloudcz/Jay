import 'dart:convert';
import 'dart:math';

import 'package:calltype_core/storage/secret_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
///
/// ## iOS keychain accessibility
///
/// Every item is written with [KeychainAccessibility.first_unlock_this_device]
/// instead of the plugin default `unlocked` (gap-calls §5.4, contracts §5).
/// A VoIP push for an incoming call can launch the app while the iPhone is
/// locked; with `unlocked` items `main()` cannot read `ct_device_id` or the
/// device secret, never connects, and the call is lost. All items, not only
/// those two, because the same launch runs the inbox, which needs the
/// identity and pre-keys to decrypt. `_this_device` additionally keeps the
/// keys out of iCloud/iTunes backups: they never migrate to another phone.
///
/// Items written by older builds still carry `unlocked`. The keychain matches
/// on the accessibility attribute, so a read with the new options does not
/// find them and a write with the new options collides with them
/// (errSecDuplicateItem). Hence [migrateKeychainAccessibility] at start-up,
/// a legacy fallback in [read] and a collision fallback in [write].
class SecureStorage extends SecretStore {
  SecureStorage({FlutterSecureStorage? storage, bool? migrateAppleKeychain})
    : _storage = storage ?? const FlutterSecureStorage(iOptions: _iosOptions),
      _appleMigration =
          migrateAppleKeychain ??
          (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS);

  final FlutterSecureStorage _storage;

  /// Whether the iOS accessibility migration and legacy fallbacks run.
  /// Other platforms ignore `iOptions`, so there is nothing to migrate.
  final bool _appleMigration;

  static const _iosOptions = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  );

  /// What builds before the migration wrote (the plugin default).
  static const _legacyIosOptions = IOSOptions(
    accessibility: KeychainAccessibility.unlocked,
  );

  /// Prefix of the crash-safety copy kept while one item is being rewritten.
  /// Deliberately outside the 'ct_' namespace so it can never shadow a real
  /// key.
  @visibleForTesting
  static const migrationBackupPrefix = 'jay_migrating.';

  /// OSStatus errSecDuplicateItem, reported by the plugin in
  /// `PlatformException.details`.
  static const _errSecDuplicateItem = -25299;

  // -- Key constants -------------------------------------------------------

  static const _keyDbKey = 'ct_db_key';
  static const _keyPinHash = 'ct_pin_hash';
  static const _keyAccountId = 'ct_account_id';
  static const _keyAccountEmail = 'ct_account_email';
  static const _keyBackupKey = 'ct_backup_key_v1';
  static const _keyBackupSalt = 'ct_backup_salt_v1';

  // -- Database encryption key ---------------------------------------------

  /// Returns the 32-byte database encryption key, generating and
  /// persisting a new one on first call.
  ///
  /// The key is stored as a base64 string in the platform keychain.
  /// Once created it must never change — doing so would make the
  /// encrypted database unreadable.
  Future<List<int>> getOrCreateDbKey() async {
    final existing = await read(_keyDbKey);
    if (existing != null) {
      return base64Decode(existing);
    }

    // Cryptographically secure random 32-byte key.
    final rng = Random.secure();
    final key = List<int>.generate(32, (_) => rng.nextInt(256));

    await write(_keyDbKey, base64Encode(key));
    return key;
  }

  // -- PIN / biometric lock ------------------------------------------------

  /// Retrieves the stored PIN hash, or null if no PIN is set.
  /// The hash is computed client-side (e.g. SHA-256) before storage
  /// so the raw PIN never touches disk.
  Future<String?> getPinHash() => read(_keyPinHash);

  /// Stores a new PIN hash, overwriting any previous value.
  Future<void> setPinHash(String hash) => write(_keyPinHash, hash);

  /// Removes the PIN hash, effectively disabling PIN lock.
  Future<void> deletePinHash() => delete(_keyPinHash);

  // -- Account -------------------------------------------------------------

  Future<String?> getAccountId() => read(_keyAccountId);

  Future<void> setAccountId(String id) => write(_keyAccountId, id);

  /// The registered account's e-mail, kept only to show it in settings (the
  /// server never returns it to a device).
  Future<String?> getAccountEmail() => read(_keyAccountEmail);

  Future<void> setAccountEmail(String email) => write(_keyAccountEmail, email);

  // -- Backup (stream D) ---------------------------------------------------

  /// The passphrase-derived backup key (base64), kept so automatic backups
  /// can run without asking for the passphrase each time.
  Future<String?> getBackupKey() => read(_keyBackupKey);

  Future<void> setBackupKey(String b64) => write(_keyBackupKey, b64);

  Future<void> deleteBackupKey() => delete(_keyBackupKey);

  /// Salt the backup key was derived with (base64).
  Future<String?> getBackupSalt() => read(_keyBackupSalt);

  Future<void> setBackupSalt(String b64) => write(_keyBackupSalt, b64);

  /// Forgets everything tied to the account (sign-out / account deletion);
  /// the device identity stays, the anonymous device keeps working.
  Future<void> clearAccount() async {
    for (final key in const [
      _keyAccountId,
      _keyAccountEmail,
      _keyBackupKey,
      _keyBackupSalt,
    ]) {
      await delete(key);
    }
  }

  /// Wipes every item of this app (device deletion, GDPR). The plugin
  /// deletes regardless of accessibility, so legacy items go too.
  Future<void> deleteAll() => _storage.deleteAll();

  // -- Generic access ------------------------------------------------------

  /// Read an arbitrary key from secure storage.
  ///
  /// On iOS falls back to the legacy accessibility for an item that start-up
  /// migration has not rewritten yet (e.g. the phone was locked then). The
  /// legacy read is not swallowed on error: answering "no device id" for an
  /// existing but locked item would send the app into onboarding and
  /// register a second identity.
  @override
  Future<String?> read(String key) async {
    final value = await _storage.read(key: key);
    if (value != null || !_appleMigration) return value;
    return _storage.read(key: key, iOptions: _legacyIosOptions);
  }

  /// Write an arbitrary key-value pair to secure storage.
  @override
  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } on PlatformException catch (e) {
      // A legacy item under the same key blocks the add; replace it.
      if (!_appleMigration || e.details != _errSecDuplicateItem) rethrow;
      await _replace(key, value);
    }
  }

  /// Delete an arbitrary key from secure storage (any accessibility).
  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  // -- iOS accessibility migration -----------------------------------------

  /// Rewrites every keychain item still carrying the legacy `unlocked`
  /// accessibility with `first_unlock_this_device`. Call once at start-up
  /// before anything reads the store.
  ///
  /// Crash-safe: each value is first copied to `jay_migrating.<key>` (new
  /// accessibility), then the old item is deleted and rewritten, verified,
  /// and only then the copy removed. A copy found on the next start means
  /// the previous run stopped mid-item; the rewrite is finished from it, so
  /// no value is ever lost — for `ct_device_secret` a loss would mean
  /// re-registering the device.
  ///
  /// Idempotent and cheap once done (one empty keychain query). Never
  /// throws: when the phone is locked (VoIP launch before the first unlock
  /// with this build) legacy items are unreadable, the migration is skipped
  /// and retried on the next start; [read] covers the meantime.
  Future<void> migrateKeychainAccessibility() async {
    if (!_appleMigration) return;
    try {
      // 1. Finish an interrupted rewrite first.
      final current = await _storage.readAll();
      for (final entry in current.entries) {
        if (!entry.key.startsWith(migrationBackupPrefix)) continue;
        await _replace(
          entry.key.substring(migrationBackupPrefix.length),
          entry.value,
        );
      }
      // 2. Rewrite what still has the legacy accessibility.
      final legacy = await _storage.readAll(iOptions: _legacyIosOptions);
      for (final entry in legacy.entries) {
        if (entry.key.startsWith(migrationBackupPrefix)) {
          // A copy never has the legacy accessibility; stale junk, drop it.
          await _storage.delete(key: entry.key);
          continue;
        }
        await _replace(entry.key, entry.value);
      }
    } catch (e) {
      debugPrint('Keychain accessibility migration deferred: $e');
    }
  }

  /// Replaces whatever item [key] has (any accessibility) with [value] under
  /// the new accessibility, keeping a copy until the new item is verified.
  Future<void> _replace(String key, String value) async {
    final backupKey = '$migrationBackupPrefix$key';
    await _storage.write(key: backupKey, value: value);
    // delete() matches every accessibility, so the legacy item goes too.
    await _storage.delete(key: key);
    await _storage.write(key: key, value: value);
    final check = await _storage.read(key: key);
    if (check != value) {
      // Keep the copy; the next start retries from it.
      throw StateError('keychain rewrite of $key could not be verified');
    }
    await _storage.delete(key: backupKey);
  }
}
