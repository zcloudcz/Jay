import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:calltype/core/crypto/backup_crypto.dart';

void main() {
  group('BackupCrypto', () {
    group('deriveKey', () {
      test('Unicode passphrase matches UTF-8 PBKDF2 reference vector', () {
        final key = BackupCrypto.deriveKey(
          'žluťoučký🔐',
          Uint8List.fromList(List.generate(16, (i) => i + 1)),
        );
        expect(
          key.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
          'dc98fb2cb051ba497237394eda72210fd86cbc346c2b35c371cb0488cc5a68a2',
        );
      });
      test('produces 32-byte key', () {
        // AES-256 requires exactly 32 bytes. Verify the output length
        // matches regardless of passphrase or salt length.
        final salt = Uint8List.fromList(List.filled(16, 0x42));
        final key = BackupCrypto.deriveKey('test-passphrase', salt);

        expect(key.length, equals(32));
        expect(key, isA<Uint8List>());
      });

      test('is deterministic — same passphrase and salt produce same key', () {
        // PBKDF2 must be deterministic so that a backup encrypted today
        // can be decrypted tomorrow with the same passphrase + salt.
        final salt = Uint8List.fromList(List.filled(16, 0xAA));
        const passphrase = 'my-backup-password';

        final key1 = BackupCrypto.deriveKey(passphrase, salt);
        final key2 = BackupCrypto.deriveKey(passphrase, salt);

        expect(key1, equals(key2));
      });

      test('different passphrases produce different keys', () {
        // Two users with different passphrases must get different keys
        // even if they happen to use the same salt.
        final salt = Uint8List.fromList(List.filled(16, 0xBB));

        final key1 = BackupCrypto.deriveKey('password-alpha', salt);
        final key2 = BackupCrypto.deriveKey('password-beta', salt);

        expect(key1, isNot(equals(key2)));
      });

      test('different salts produce different keys', () {
        // Different salts ensure that even identical passphrases yield
        // unique keys — prevents rainbow table attacks across backups.
        const passphrase = 'same-passphrase';
        final salt1 = Uint8List.fromList(List.filled(16, 0x01));
        final salt2 = Uint8List.fromList(List.filled(16, 0x02));

        final key1 = BackupCrypto.deriveKey(passphrase, salt1);
        final key2 = BackupCrypto.deriveKey(passphrase, salt2);

        expect(key1, isNot(equals(key2)));
      });
    });

    group('generateSalt', () {
      test('produces 16 bytes', () {
        // 16 bytes = 128 bits of entropy, sufficient to prevent
        // precomputed rainbow table attacks.
        final salt = BackupCrypto.generateSalt();

        expect(salt.length, equals(16));
        expect(salt, isA<Uint8List>());
      });

      test('produces unique values on successive calls', () {
        // Cryptographically secure RNG should never produce identical
        // 16-byte sequences in practice.
        final salt1 = BackupCrypto.generateSalt();
        final salt2 = BackupCrypto.generateSalt();

        expect(salt1, isNot(equals(salt2)));
      });
    });

    group('encrypt / decrypt (AES-256-GCM)', () {
      /// Helper to create a deterministic 32-byte key for testing.
      /// NOT for production — real keys come from deriveKey().
      Uint8List testKey(int fill) => Uint8List.fromList(List.filled(32, fill));

      test('encrypt then decrypt roundtrip', () async {
        // The fundamental correctness check: encrypting then decrypting
        // must yield the original plaintext byte-for-byte.
        final key = testKey(0x42);
        final plaintext = Uint8List.fromList(
          [72, 101, 108, 108, 111], // "Hello"
        );

        final encrypted = await BackupCrypto.encrypt(key, plaintext);
        final decrypted = await BackupCrypto.decrypt(key, encrypted);

        expect(decrypted, equals(plaintext));
      });

      test('different keys produce different ciphertext', () async {
        // If two different keys produce the same ciphertext, the encryption
        // is broken — an attacker with one key could read data encrypted
        // with the other.
        final key1 = testKey(0x42);
        final key2 = testKey(0x43);
        final plaintext = Uint8List.fromList([1, 2, 3, 4, 5]);

        final encrypted1 = await BackupCrypto.encrypt(key1, plaintext);
        final encrypted2 = await BackupCrypto.encrypt(key2, plaintext);

        // The nonce differs too, so the entire output should differ.
        expect(encrypted1, isNot(equals(encrypted2)));
      });

      test('tampered ciphertext fails decryption', () async {
        // AES-GCM's authentication tag detects any modification to the
        // ciphertext. This is critical for backup integrity: a corrupted
        // backup should fail loudly rather than restore garbage data.
        final key = testKey(0x42);
        final plaintext = Uint8List.fromList([1, 2, 3, 4, 5]);

        final encrypted = await BackupCrypto.encrypt(key, plaintext);

        // Flip a bit in the ciphertext region (after 12-byte nonce,
        // before 16-byte tag).
        encrypted[15] ^= 0xFF;

        expect(
          () => BackupCrypto.decrypt(key, encrypted),
          throwsA(isA<Object>()),
        );
      });

      test(
        'encrypted output has correct format (nonce + ciphertext + tag)',
        () async {
          // Wire format: [12-byte nonce][N-byte ciphertext][16-byte GCM tag]
          // AES-GCM in CTR mode produces ciphertext the same length as plaintext.
          final key = testKey(0x42);
          final plaintext = Uint8List.fromList([1, 2, 3, 4, 5]);

          final encrypted = await BackupCrypto.encrypt(key, plaintext);

          // 12 (nonce) + 5 (plaintext length = ciphertext length) + 16 (tag)
          expect(encrypted.length, equals(12 + plaintext.length + 16));
        },
      );

      test('wrong key fails decryption (wrong passphrase scenario)', () async {
        // Simulates a user entering the wrong passphrase during restore.
        // The derived key won't match, and GCM auth check must fail.
        final correctKey = testKey(0x42);
        final wrongKey = testKey(0x99);
        final plaintext = Uint8List.fromList([1, 2, 3, 4, 5]);

        final encrypted = await BackupCrypto.encrypt(correctKey, plaintext);

        expect(
          () => BackupCrypto.decrypt(wrongKey, encrypted),
          throwsA(isA<Object>()),
        );
      });

      test('encrypting same data twice produces different output', () async {
        // AES-GCM uses a random nonce per call. Same key + plaintext must
        // produce different ciphertext — otherwise an eavesdropper could
        // detect when the user creates identical backups.
        final key = testKey(0x42);
        final plaintext = Uint8List.fromList([1, 2, 3, 4, 5]);

        final encrypted1 = await BackupCrypto.encrypt(key, plaintext);
        final encrypted2 = await BackupCrypto.encrypt(key, plaintext);

        expect(encrypted1, isNot(equals(encrypted2)));
      });

      test('large payload roundtrip', () async {
        // Backups can be megabytes. Verify that non-trivial payloads
        // encrypt and decrypt correctly (catches buffer/offset bugs).
        final key = testKey(0x42);
        final plaintext = Uint8List.fromList(
          List.generate(10000, (i) => i % 256),
        );

        final encrypted = await BackupCrypto.encrypt(key, plaintext);
        final decrypted = await BackupCrypto.decrypt(key, encrypted);

        expect(decrypted, equals(plaintext));
      });
    });
  });
}
