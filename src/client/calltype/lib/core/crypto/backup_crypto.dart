import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Handles backup encryption key derivation.
///
/// Backup encryption is independent from the Signal Protocol session keys.
/// The user chooses a passphrase, and we derive a symmetric encryption key
/// from it using PBKDF2. This key encrypts the entire backup blob before
/// upload to Azure Blob Storage.
///
/// Key design decisions:
///   - PBKDF2 with HMAC-SHA256 is used instead of Argon2id because the
///     `crypto` package provides it natively. The server-side auth key
///     uses Argon2id (implemented in the backend), but for client-side
///     backup encryption PBKDF2 with high iteration count is acceptable.
///   - 600,000 iterations follows OWASP 2024 recommendations for PBKDF2-SHA256.
///   - 16-byte random salt ensures unique derived keys even for identical
///     passphrases across different backups.
class BackupCrypto {
  BackupCrypto._();

  /// OWASP-recommended minimum for PBKDF2-SHA256 (2024 guidelines).
  /// High iteration count compensates for SHA-256 being GPU-friendly
  /// compared to memory-hard functions like Argon2.
  static const int _iterations = 600000;

  /// AES-256 requires a 32-byte key.
  static const int _keyLengthBytes = 32;

  /// Salt length — 16 bytes provides 128 bits of entropy, which is
  /// sufficient to make precomputed rainbow tables infeasible.
  static const int _saltLengthBytes = 16;

  /// Derives a 32-byte encryption key from a user passphrase and salt.
  ///
  /// Uses PBKDF2 with HMAC-SHA256 and 600k iterations. The same
  /// passphrase + salt always produces the same key, which is essential
  /// for decrypting backups later.
  ///
  /// [passphrase] is the user's chosen backup password.
  /// [salt] must be stored alongside the encrypted backup so decryption
  /// can re-derive the same key.
  static Uint8List deriveKey(String passphrase, Uint8List salt) {
    final hmac = Hmac(sha256, passphrase.codeUnits);

    // PBKDF2 iteratively applies HMAC to stretch the passphrase into
    // a key that is computationally expensive to brute-force.
    var block = Uint8List.fromList([...salt, 0, 0, 0, 1]);
    var u = hmac.convert(block).bytes;
    var result = Uint8List.fromList(u);

    for (var i = 1; i < _iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < result.length; j++) {
        result[j] ^= u[j];
      }
    }

    return Uint8List.fromList(result.sublist(0, _keyLengthBytes));
  }

  /// Generates a cryptographically secure random salt.
  ///
  /// Must be stored alongside the encrypted backup metadata so the
  /// key can be re-derived during restore.
  static Uint8List generateSalt() {
    final rng = Random.secure();
    return Uint8List.fromList(
      List.generate(_saltLengthBytes, (_) => rng.nextInt(256)),
    );
  }
}
