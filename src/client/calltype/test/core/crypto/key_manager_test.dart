import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:calltype/core/crypto/signal_protocol.dart';

/// Tests for key generation logic used by [KeyManager].
///
/// KeyManager itself depends on SecureStorage (flutter_secure_storage)
/// which requires platform channels unavailable in unit tests. Instead
/// we test the underlying [SignalProtocol.generateIdentityKeyPair] static
/// method directly — this is where the actual key material originates.
void main() {
  group('SignalProtocol.generateIdentityKeyPair', () {
    test('returns publicKey and privateKey', () {
      final keyPair = SignalProtocol.generateIdentityKeyPair();

      // Both keys must be present in the returned map.
      expect(keyPair, contains('publicKey'));
      expect(keyPair, contains('privateKey'));
      expect(keyPair['publicKey'], isNotEmpty);
      expect(keyPair['privateKey'], isNotEmpty);
    });

    test('keys are valid base64 encoded strings', () {
      final keyPair = SignalProtocol.generateIdentityKeyPair();

      // base64Decode throws FormatException on invalid input.
      // A valid 32-byte key encodes to a 44-character base64 string.
      final publicBytes = base64Decode(keyPair['publicKey']!);
      final privateBytes = base64Decode(keyPair['privateKey']!);

      expect(publicBytes.length, equals(32));
      expect(privateBytes.length, equals(32));
    });

    test('two calls produce different keys (random generation)', () {
      // Each identity key pair must be unique — reuse would be a
      // catastrophic security failure in Signal Protocol.
      final keyPair1 = SignalProtocol.generateIdentityKeyPair();
      final keyPair2 = SignalProtocol.generateIdentityKeyPair();

      expect(keyPair1['publicKey'], isNot(equals(keyPair2['publicKey'])));
      expect(keyPair1['privateKey'], isNot(equals(keyPair2['privateKey'])));
    });
  });

  group('SignalProtocol.generatePreKeys', () {
    test('produces the requested number of pre-keys', () {
      final preKeys = SignalProtocol.generatePreKeys(1, 5);

      expect(preKeys.length, equals(5));
    });

    test('each pre-key has sequential keyId starting from startId', () {
      const startId = 10;
      final preKeys = SignalProtocol.generatePreKeys(startId, 3);

      for (var i = 0; i < 3; i++) {
        expect(preKeys[i]['keyId'], equals(startId + i));
      }
    });

    test('each pre-key contains base64-encoded publicKey and privateKey', () {
      final preKeys = SignalProtocol.generatePreKeys(0, 1);
      final key = preKeys.first;

      // Verify both keys decode without error and are 32 bytes.
      final pub = base64Decode(key['publicKey'] as String);
      final priv = base64Decode(key['privateKey'] as String);
      expect(pub.length, equals(32));
      expect(priv.length, equals(32));
    });
  });

  group('SignalProtocol.generateSignedPreKey', () {
    test('returns keyId, publicKey, privateKey, and signature', () {
      final spk = SignalProtocol.generateSignedPreKey(42);

      expect(spk['keyId'], equals(42));
      expect(spk, contains('publicKey'));
      expect(spk, contains('privateKey'));
      expect(spk, contains('signature'));
    });

    test('signature is base64 encoded (64 bytes)', () {
      final spk = SignalProtocol.generateSignedPreKey(1);

      // The placeholder generates a 64-byte random signature.
      final sigBytes = base64Decode(spk['signature'] as String);
      expect(sigBytes.length, equals(64));
    });
  });
}
