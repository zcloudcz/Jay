import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:calltype_core/crypto/signal_protocol.dart';

/// Tests for cryptographic key generation and key agreement.
///
/// Tests both the synchronous compatibility API (generateIdentityKeyPair)
/// and the real async X25519 operations (generateKeyPair, keyAgreement).
/// KeyManager itself depends on SecureStorage which requires platform
/// channels, so we test the underlying SignalProtocol methods directly.
void main() {
  group('SignalProtocol.generateIdentityKeyPair (sync compatibility)', () {
    test('returns publicKey and privateKey', () {
      final keyPair = SignalProtocol.generateIdentityKeyPair();

      // Both keys must be present in the returned map.
      expect(keyPair, contains('publicKey'));
      expect(keyPair, contains('privateKey'));
      expect(keyPair['publicKey'], isNotEmpty);
      expect(keyPair['privateKey'], isNotEmpty);
    });

    test('keys are valid base64 encoded strings of 32 bytes', () {
      final keyPair = SignalProtocol.generateIdentityKeyPair();

      // base64Decode throws FormatException on invalid input.
      // X25519 keys are always 32 bytes (256 bits).
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

  group('SignalProtocol.generateKeyPair (real X25519)', () {
    test('returns valid base64 publicKey and privateKey', () async {
      // The async version produces a real X25519 key pair where the
      // public key is mathematically derived from the private seed.
      final keyPair = await SignalProtocol.generateKeyPair();

      expect(keyPair, contains('publicKey'));
      expect(keyPair, contains('privateKey'));

      final publicBytes = base64Decode(keyPair['publicKey']!);
      final privateBytes = base64Decode(keyPair['privateKey']!);

      // X25519 keys are always 32 bytes.
      expect(publicBytes.length, equals(32));
      expect(privateBytes.length, equals(32));
    });

    test('two calls produce different key pairs', () async {
      final keyPair1 = await SignalProtocol.generateKeyPair();
      final keyPair2 = await SignalProtocol.generateKeyPair();

      expect(keyPair1['publicKey'], isNot(equals(keyPair2['publicKey'])));
      expect(keyPair1['privateKey'], isNot(equals(keyPair2['privateKey'])));
    });
  });

  group('SignalProtocol.keyAgreement', () {
    test('produces a 32-byte shared secret', () async {
      // X25519 DH always yields a 32-byte shared secret regardless of
      // the input key sizes.
      final alice = await SignalProtocol.generateKeyPair();
      final bob = await SignalProtocol.generateKeyPair();

      final sharedSecret = await SignalProtocol.keyAgreement(
        alice['privateKey']!,
        bob['publicKey']!,
      );

      expect(sharedSecret.length, equals(32));
    });

    test('two parties derive the same shared secret', () async {
      // The fundamental property of Diffie-Hellman: Alice's private × Bob's
      // public must equal Bob's private × Alice's public. If this fails,
      // encryption/decryption will produce different keys on each side.
      final alice = await SignalProtocol.generateKeyPair();
      final bob = await SignalProtocol.generateKeyPair();

      final secretAlice = await SignalProtocol.keyAgreement(
        alice['privateKey']!,
        bob['publicKey']!,
      );
      final secretBob = await SignalProtocol.keyAgreement(
        bob['privateKey']!,
        alice['publicKey']!,
      );

      expect(secretAlice, equals(secretBob));
    });

    test('different key pairs produce different shared secrets', () async {
      // If two different peers yield the same shared secret, messages
      // would be readable by unintended recipients — catastrophic.
      final alice = await SignalProtocol.generateKeyPair();
      final bob = await SignalProtocol.generateKeyPair();
      final carol = await SignalProtocol.generateKeyPair();

      final secretAliceBob = await SignalProtocol.keyAgreement(
        alice['privateKey']!,
        bob['publicKey']!,
      );
      final secretAliceCarol = await SignalProtocol.keyAgreement(
        alice['privateKey']!,
        carol['publicKey']!,
      );

      expect(secretAliceBob, isNot(equals(secretAliceCarol)));
    });
  });

  group('SignalProtocol.deriveKey (HKDF)', () {
    test('produces output of requested length', () async {
      final ikm = List<int>.filled(32, 0x42);
      final salt = List<int>.filled(32, 0xAA);
      final info = [0x01, 0x02, 0x03];

      // Request 64 bytes — enough for root key + chain key.
      final derived = await SignalProtocol.deriveKey(ikm, salt, info, 64);
      expect(derived.length, equals(64));
    });

    test('same inputs produce same output (deterministic)', () async {
      final ikm = List<int>.filled(32, 0x42);
      final salt = List<int>.filled(32, 0xAA);
      final info = [0x01, 0x02, 0x03];

      final derived1 = await SignalProtocol.deriveKey(ikm, salt, info, 32);
      final derived2 = await SignalProtocol.deriveKey(ikm, salt, info, 32);

      expect(derived1, equals(derived2));
    });

    test('different info strings produce different outputs', () async {
      // Domain separation: "msg-key" and "chain-key" must yield different
      // derived keys from the same input material.
      final ikm = List<int>.filled(32, 0x42);
      final salt = List<int>.filled(32, 0xAA);

      final derived1 = await SignalProtocol.deriveKey(
        ikm,
        salt,
        [0x01],
        32,
      );
      final derived2 = await SignalProtocol.deriveKey(
        ikm,
        salt,
        [0x02],
        32,
      );

      expect(derived1, isNot(equals(derived2)));
    });
  });

  group('SignalProtocol.encrypt / decrypt (AES-256-GCM)', () {
    test('encrypt then decrypt roundtrip', () async {
      // The most critical test: what goes in must come out unchanged.
      final key = List<int>.filled(32, 0x42);
      final plaintext = [0x48, 0x65, 0x6C, 0x6C, 0x6F]; // "Hello"

      final encrypted = await SignalProtocol.encrypt(key, plaintext);
      final decrypted = await SignalProtocol.decrypt(key, encrypted);

      expect(decrypted, equals(plaintext));
    });

    test('encrypted output has correct format (nonce + ciphertext + tag)',
        () async {
      final key = List<int>.filled(32, 0x42);
      final plaintext = [0x01, 0x02, 0x03];

      final encrypted = await SignalProtocol.encrypt(key, plaintext);

      // Minimum size: 12 (nonce) + plaintext.length (ciphertext) + 16 (tag)
      // GCM ciphertext is the same length as plaintext.
      expect(encrypted.length, equals(12 + plaintext.length + 16));
    });

    test('different encryptions of same plaintext produce different output',
        () async {
      // AES-GCM uses a random nonce per encryption. Same key + plaintext
      // must produce different ciphertext — otherwise an attacker could
      // detect duplicate messages.
      final key = List<int>.filled(32, 0x42);
      final plaintext = [0x48, 0x65, 0x6C, 0x6C, 0x6F];

      final encrypted1 = await SignalProtocol.encrypt(key, plaintext);
      final encrypted2 = await SignalProtocol.encrypt(key, plaintext);

      expect(encrypted1, isNot(equals(encrypted2)));
    });

    test('wrong key fails decryption', () async {
      // GCM's authentication tag ensures wrong-key decryption throws
      // rather than producing garbage data silently.
      final key1 = List<int>.filled(32, 0x42);
      final key2 = List<int>.filled(32, 0x43);
      final plaintext = [0x48, 0x65, 0x6C, 0x6C, 0x6F];

      final encrypted = await SignalProtocol.encrypt(key1, plaintext);

      expect(
        () => SignalProtocol.decrypt(key2, encrypted),
        throwsA(isA<Object>()),
      );
    });

    test('tampered ciphertext fails decryption', () async {
      // GCM detects any modification to the ciphertext — even a single
      // flipped bit causes authentication failure.
      final key = List<int>.filled(32, 0x42);
      final plaintext = [0x48, 0x65, 0x6C, 0x6C, 0x6F];

      final encrypted = await SignalProtocol.encrypt(key, plaintext);

      // Flip a bit in the ciphertext region (after nonce, before tag).
      encrypted[15] ^= 0xFF;

      expect(
        () => SignalProtocol.decrypt(key, encrypted),
        throwsA(isA<Object>()),
      );
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

  group('SignalProtocol.sign / verify (Ed25519)', () {
    test('sign then verify roundtrip', () async {
      final signingKeyPair = await SignalProtocol.generateSigningKeyPair();
      final data = Uint8List.fromList([0x01, 0x02, 0x03, 0x04]);

      final signature = await SignalProtocol.sign(
        data,
        signingKeyPair['privateKey']!,
      );

      final isValid = await SignalProtocol.verify(
        data,
        signature,
        signingKeyPair['publicKey']!,
      );

      expect(isValid, isTrue);
    });

    test('wrong public key fails verification', () async {
      final signingKeyPair = await SignalProtocol.generateSigningKeyPair();
      final otherKeyPair = await SignalProtocol.generateSigningKeyPair();
      final data = Uint8List.fromList([0x01, 0x02, 0x03, 0x04]);

      final signature = await SignalProtocol.sign(
        data,
        signingKeyPair['privateKey']!,
      );

      // Verify with a different public key — must fail.
      final isValid = await SignalProtocol.verify(
        data,
        signature,
        otherKeyPair['publicKey']!,
      );

      expect(isValid, isFalse);
    });

    test('tampered data fails verification', () async {
      final signingKeyPair = await SignalProtocol.generateSigningKeyPair();
      final data = Uint8List.fromList([0x01, 0x02, 0x03, 0x04]);

      final signature = await SignalProtocol.sign(
        data,
        signingKeyPair['privateKey']!,
      );

      // Modify the data after signing — must fail.
      final tamperedData = Uint8List.fromList([0x01, 0x02, 0x03, 0x05]);
      final isValid = await SignalProtocol.verify(
        tamperedData,
        signature,
        signingKeyPair['publicKey']!,
      );

      expect(isValid, isFalse);
    });
  });
}
