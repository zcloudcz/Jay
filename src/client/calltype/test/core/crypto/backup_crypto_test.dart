import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:calltype/core/crypto/backup_crypto.dart';

void main() {
  group('BackupCrypto', () {
    group('deriveKey', () {
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
  });
}
