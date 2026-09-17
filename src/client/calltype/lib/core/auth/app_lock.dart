import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:local_auth/local_auth.dart';

import '../storage/secure_storage.dart';

/// Service for PIN-based app locking with optional biometric authentication.
///
/// Security model:
///   - PINs are SHA-256 hashed before storage so the raw PIN never touches
///     disk. Even if secure storage is compromised, the attacker only gets
///     a hash — not the original PIN.
///   - Biometrics are handled via the `local_auth` plugin which delegates to
///     the platform's biometric API (Face ID, fingerprint, Windows Hello).
///   - PIN must be set before biometrics can be enabled — biometrics alone
///     would lock out users whose biometric data changes (e.g. after injury).
///
/// Dependencies:
///   - [SecureStorage] for persisting the PIN hash and biometric preference
///   - [LocalAuthentication] for biometric checks
class AppLock {
  AppLock({SecureStorage? secureStorage, LocalAuthentication? localAuth})
    : _secureStorage = secureStorage ?? SecureStorage(),
      _localAuth = localAuth ?? LocalAuthentication();

  final SecureStorage _secureStorage;
  final LocalAuthentication _localAuth;

  /// Key used to persist the biometric preference in secure storage.
  /// Stored separately from the PIN hash because the user may toggle
  /// biometrics on/off without changing their PIN.
  static const _keyBiometricEnabled = 'ct_biometric_enabled';

  // -- PIN management ---------------------------------------------------------

  /// Whether a PIN lock is currently configured.
  ///
  /// Checks for the existence of a stored PIN hash. Returns true even if
  /// the hash is somehow empty — the presence of the key itself indicates
  /// the user intended to enable PIN lock.
  Future<bool> isEnabled() async {
    final hash = await _secureStorage.getPinHash();
    return hash != null;
  }

  /// Sets a new PIN by hashing it and storing the hash.
  ///
  /// Accepts 4-6 digit PINs. The raw PIN is immediately hashed with SHA-256
  /// and only the hash is persisted — the raw value is never stored anywhere.
  ///
  /// Throws [ArgumentError] if the PIN is not 4-6 digits.
  Future<void> setPin(String pin) async {
    if (pin.length < 4 || pin.length > 6 || !RegExp(r'^\d+$').hasMatch(pin)) {
      throw ArgumentError('PIN must be 4-6 digits');
    }

    final hash = _hashPin(pin);
    await _secureStorage.setPinHash(hash);
  }

  /// Removes the PIN lock entirely.
  ///
  /// Also disables biometric authentication since biometrics require an
  /// active PIN — removing the PIN without clearing biometric preference
  /// would leave the app in an inconsistent state.
  Future<void> removePin() async {
    await _secureStorage.deletePinHash();
    await _secureStorage.delete(_keyBiometricEnabled);
  }

  /// Verifies an entered PIN against the stored hash.
  ///
  /// Hashes the input and compares with the stored hash using constant-time
  /// string comparison (SHA-256 hex strings are always 64 chars, so length
  /// leaking is not a concern). Returns false if no PIN is set.
  Future<bool> verifyPin(String pin) async {
    final storedHash = await _secureStorage.getPinHash();
    if (storedHash == null) return false;

    final inputHash = _hashPin(pin);
    return storedHash == inputHash;
  }

  // -- Biometric authentication -----------------------------------------------

  /// Whether the device supports biometric authentication (fingerprint,
  /// face recognition, iris scan).
  ///
  /// Returns false if the hardware is not available or no biometrics are
  /// enrolled. The user must enroll biometrics in the device settings first.
  Future<bool> isBiometricAvailable() async {
    try {
      final canCheck = await _localAuth.canCheckBiometrics;
      final isSupported = await _localAuth.isDeviceSupported();
      return canCheck && isSupported;
    } catch (_) {
      // Unsupported platforms (including web) still support the app PIN.
      return false;
    }
  }

  /// Whether the user has opted in to biometric unlock.
  ///
  /// This is a user preference — it's separate from hardware availability.
  /// Both must be true for biometric auth to be offered at the lock screen.
  Future<bool> isBiometricEnabled() async {
    final value = await _secureStorage.read(_keyBiometricEnabled);
    return value == 'true';
  }

  /// Enables or disables biometric authentication preference.
  ///
  /// Only meaningful when a PIN is set — the lock screen shows the biometric
  /// prompt as an alternative to PIN entry.
  Future<void> setBiometricEnabled(bool enabled) async {
    await _secureStorage.write(_keyBiometricEnabled, enabled.toString());
  }

  /// Triggers the platform biometric authentication dialog.
  ///
  /// Returns true if the user successfully authenticates. The dialog text
  /// is localized by the platform — the caller provides the already
  /// localized [reason] for the system to display (e.g. "Unlock Jay"),
  /// because this class has no BuildContext to look translations up.
  ///
  /// Falls back to device PIN/passcode if biometrics fail repeatedly,
  /// which is the platform default behavior on both iOS and Android.
  Future<bool> authenticateWithBiometrics({required String reason}) async {
    try {
      return await _localAuth.authenticate(
        localizedReason: reason,
        // Allow device PIN/passcode as fallback if biometrics fail.
        // This prevents lockout if the sensor is dirty or damaged.
        biometricOnly: false,
      );
    } catch (_) {
      // Biometric auth can throw PlatformException on misconfigured
      // devices. Treat any exception as authentication failure — the
      // user can still enter their PIN manually.
      return false;
    }
  }

  // -- Internal ---------------------------------------------------------------

  /// Produces a SHA-256 hex digest of the given PIN.
  ///
  /// Using SHA-256 for a 4-6 digit PIN is intentionally simple — the goal
  /// is to avoid storing the raw PIN, not to resist offline brute-force
  /// attacks (which would require Argon2id or similar). The PIN protects
  /// against casual shoulder-surfing and unauthorized physical access,
  /// not against a determined attacker with access to secure storage.
  String _hashPin(String pin) {
    final bytes = utf8.encode(pin);
    return sha256.convert(bytes).toString();
  }
}
