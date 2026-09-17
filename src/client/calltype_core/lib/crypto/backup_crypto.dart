import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as aes;

/// Handles backup encryption: key derivation from passphrase + AES-256-GCM
/// authenticated encryption of the backup blob.
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
///   - AES-256-GCM provides authenticated encryption: both confidentiality
///     AND integrity. A tampered backup will fail decryption rather than
///     silently producing garbage data.
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

  /// AES-256-GCM instance. The 256-bit variant is used because we derive
  /// a 32-byte key from PBKDF2 — using AES-128 would waste half the
  /// key material.
  static final _aesGcm = aes.AesGcm.with256bits();

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
    final hmac = Hmac(sha256, utf8.encode(passphrase));

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

  /// Encrypts data with AES-256-GCM.
  ///
  /// Returns a byte array in the format:
  /// [12-byte nonce][ciphertext][16-byte GCM authentication tag]
  ///
  /// The nonce is randomly generated per encryption — reusing a nonce with
  /// the same key completely breaks GCM's confidentiality guarantees.
  /// The GCM tag provides integrity: any tampering with the ciphertext
  /// or nonce will cause decryption to fail with an authentication error
  /// rather than silently producing corrupted data.
  static Future<Uint8List> encrypt(Uint8List key, Uint8List plaintext) async {
    final secretKey = aes.SecretKey(key);
    final secretBox = await _aesGcm.encrypt(plaintext, secretKey: secretKey);

    // Concatenate: nonce + ciphertext + MAC tag.
    // This wire format is self-describing: the receiver knows the nonce
    // is always the first 12 bytes and the tag is always the last 16.
    return Uint8List.fromList([
      ...secretBox.nonce,
      ...secretBox.cipherText,
      ...secretBox.mac.bytes,
    ]);
  }

  /// Decrypts AES-256-GCM encrypted data.
  ///
  /// Expects the format produced by [encrypt]:
  /// [12-byte nonce][ciphertext][16-byte GCM tag].
  ///
  /// Throws [aes.SecretBoxAuthenticationError] if the ciphertext, nonce,
  /// or tag has been modified — this is the integrity guarantee of GCM.
  /// A wrong passphrase will also trigger this because the derived key
  /// won't match, producing an invalid tag check.
  static Future<Uint8List> decrypt(Uint8List key, Uint8List encrypted) async {
    // Parse the wire format: first 12 bytes = nonce, last 16 = tag,
    // everything in between = ciphertext.
    final nonce = encrypted.sublist(0, 12);
    final ciphertext = encrypted.sublist(12, encrypted.length - 16);
    final mac = aes.Mac(encrypted.sublist(encrypted.length - 16));

    final secretKey = aes.SecretKey(key);
    final secretBox = aes.SecretBox(ciphertext, nonce: nonce, mac: mac);
    final plaintext = await _aesGcm.decrypt(secretBox, secretKey: secretKey);
    return Uint8List.fromList(plaintext);
  }
}
