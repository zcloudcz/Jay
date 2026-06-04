import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for AppLock's PIN hashing logic.
///
/// AppLock depends on flutter_secure_storage (platform channels) and
/// local_auth (biometric hardware), so we cannot instantiate it directly
/// in unit tests. Instead, we test the pure SHA-256 hashing function that
/// AppLock uses internally for PIN storage.
///
/// The hashing logic is extracted here as a standalone function matching
/// AppLock._hashPin's implementation. This ensures:
///   1. The hash algorithm is consistent and deterministic.
///   2. PIN hashes can be verified across app versions / platforms.
///   3. The same PIN always produces the same hash.
///
/// Integration tests with platform mocking should cover the full
/// setPin/verifyPin/removePin flow.
void main() {
  group('PIN hashing (AppLock._hashPin logic)', () {
    // Replicate AppLock._hashPin — SHA-256 of UTF-8 encoded PIN string.
    String hashPin(String pin) {
      final bytes = utf8.encode(pin);
      return sha256.convert(bytes).toString();
    }

    test('SHA-256 hash is deterministic', () {
      // The same PIN must always produce the same hash so that
      // verifyPin works across app restarts.
      const pin = '1234';
      final hash1 = hashPin(pin);
      final hash2 = hashPin(pin);

      expect(hash1, equals(hash2));
    });

    test('hash output is 64-character hex string', () {
      // SHA-256 produces a 256-bit (32-byte) digest, which is
      // represented as a 64-character lowercase hexadecimal string.
      final hash = hashPin('5678');

      expect(hash.length, equals(64));
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(hash), isTrue);
    });

    test('different PINs produce different hashes', () {
      final hash1 = hashPin('1234');
      final hash2 = hashPin('5678');

      expect(hash1, isNot(equals(hash2)));
    });

    test('known SHA-256 test vector', () {
      // Verify against a known SHA-256 value to detect algorithm
      // changes or encoding issues. SHA-256("1234") is well-known.
      final hash = hashPin('1234');

      // Expected: SHA-256 of the ASCII/UTF-8 string "1234".
      const expected =
          '03ac674216f3e15c761ee1a5e255f067953623c8b388b4459e13f978d7c846f4';
      expect(hash, equals(expected));
    });

    test('empty string hashes without error', () {
      // Although AppLock validates PIN length (4-6 digits), the hash
      // function itself should handle any input gracefully.
      final hash = hashPin('');

      expect(hash.length, equals(64));
      // SHA-256 of empty string is a known constant.
      const expected =
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
      expect(hash, equals(expected));
    });

    test('PIN validation rules — 4 to 6 digits only', () {
      // Mirror AppLock.setPin's validation regex: ^\d+$ with length 4-6.
      // This tests the validation logic, not the hash itself.
      bool isValidPin(String pin) {
        return pin.length >= 4 &&
            pin.length <= 6 &&
            RegExp(r'^\d+$').hasMatch(pin);
      }

      expect(isValidPin('1234'), isTrue);
      expect(isValidPin('12345'), isTrue);
      expect(isValidPin('123456'), isTrue);
      expect(isValidPin('123'), isFalse); // Too short.
      expect(isValidPin('1234567'), isFalse); // Too long.
      expect(isValidPin('abcd'), isFalse); // Not digits.
      expect(isValidPin('12ab'), isFalse); // Mixed.
      expect(isValidPin(''), isFalse); // Empty.
    });
  });
}
