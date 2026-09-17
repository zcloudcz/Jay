import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Core cryptographic primitives for the Signal Protocol implementation.
///
/// Provides X25519 key exchange, Ed25519 signing, HKDF key derivation,
/// and AES-256-GCM authenticated encryption — everything needed for X3DH
/// key agreement and the symmetric ratchet.
///
/// Uses the `cryptography` package which delegates to platform-native
/// implementations (BoringSSL on mobile, Web Crypto on browser) via
/// `cryptography_flutter` when available, falling back to pure Dart.
///
/// This is a SIMPLIFIED Signal Protocol — it implements X3DH key agreement
/// and a single-step symmetric ratchet (chain key → message key), but omits
/// the full Diffie-Hellman ratchet with header encryption. Acceptable for
/// MVP; a full Double Ratchet upgrade is planned for Phase 4.
class SignalProtocol {
  SignalProtocol._();

  /// X25519 for Diffie-Hellman key agreement (identity keys, pre-keys,
  /// ephemeral keys). All key exchange in Signal Protocol uses Curve25519.
  static final _x25519 = X25519();

  /// Ed25519 for signing the signed pre-key. The signature lets the
  /// initiator verify the pre-key wasn't tampered with during transit.
  static final _ed25519 = Ed25519();

  /// AES-256-GCM for message encryption. GCM provides both confidentiality
  /// and integrity (authenticated encryption), which prevents ciphertext
  /// tampering without needing a separate MAC.
  static final aesGcm = AesGcm.with256bits();

  static final _rng = Random.secure();

  /// Whether the crypto engine is ready. Always true because the `cryptography`
  /// package works without native setup — but kept for API compatibility with
  /// the original placeholder that checked for FFI library loading.
  static bool isInitialized = true;

  /// Generates an X25519 key pair for key exchange.
  ///
  /// Used for identity keys, signed pre-keys, one-time pre-keys, and
  /// ephemeral keys. Returns base64-encoded public and private keys.
  /// The private key is the 32-byte seed; the public key is the 32-byte
  /// Curve25519 point derived from it.
  static Future<Map<String, String>> generateKeyPair() async {
    final keyPair = await _x25519.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final privateBytes = await keyPair.extractPrivateKeyBytes();
    return {
      'publicKey': base64Encode(publicKey.bytes),
      'privateKey': base64Encode(privateBytes),
    };
  }

  /// Generates an Ed25519 signing key pair.
  ///
  /// Used to sign the signed pre-key so the initiator can verify it was
  /// created by the claimed identity. Ed25519 is used instead of X25519
  /// because Curve25519 points don't natively support signing — the two
  /// curves are birationally equivalent but use different encodings.
  static Future<Map<String, String>> generateSigningKeyPair() async {
    final keyPair = await _ed25519.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final privateBytes = await keyPair.extractPrivateKeyBytes();
    return {
      'publicKey': base64Encode(publicKey.bytes),
      'privateKey': base64Encode(privateBytes),
    };
  }

  /// Signs data with an Ed25519 private key.
  ///
  /// Used to sign the serialized signed pre-key public key with the
  /// identity private key, proving ownership without revealing the
  /// identity private key.
  static Future<Uint8List> sign(Uint8List data, String privateKeyB64) async {
    final privateBytes = base64Decode(privateKeyB64);
    final keyPair = await _ed25519.newKeyPairFromSeed(privateBytes);
    final signature = await _ed25519.sign(data, keyPair: keyPair);
    return Uint8List.fromList(signature.bytes);
  }

  /// Verifies an Ed25519 signature.
  ///
  /// Returns true if the signature is valid for the given data and public key.
  /// Used by the session initiator to verify the signed pre-key before
  /// trusting it for X3DH.
  static Future<bool> verify(
    Uint8List data,
    Uint8List signatureBytes,
    String publicKeyB64,
  ) async {
    final publicBytes = base64Decode(publicKeyB64);
    final publicKey = SimplePublicKey(publicBytes, type: KeyPairType.ed25519);
    final signature = Signature(signatureBytes, publicKey: publicKey);
    return _ed25519.verify(data, signature: signature);
  }

  /// Synchronous identity key pair generation using random bytes.
  ///
  /// COMPATIBILITY: The original placeholder API was synchronous. This
  /// preserved for call sites that haven't been migrated to async yet
  /// (KeyManager, existing tests). Generates cryptographically random
  /// 32-byte seeds — these are valid X25519 private keys, but the
  /// corresponding public key is NOT the X25519 derivation of the seed.
  /// For proper X25519 key pairs, use [generateKeyPair] (async).
  static Map<String, String> generateIdentityKeyPair() {
    return {
      'publicKey': _randomBase64(32),
      'privateKey': _randomBase64(32),
    };
  }

  /// Generates a batch of pre-keys for X3DH.
  ///
  /// One-time pre-keys are consumed once during session establishment and
  /// then deleted from the server. Generating them in batches (typically
  /// 100 at a time) reduces round-trips to the server.
  static List<Map<String, dynamic>> generatePreKeys(int startId, int count) {
    return List.generate(count, (i) {
      return {
        'keyId': startId + i,
        'publicKey': _randomBase64(32),
        'privateKey': _randomBase64(32),
      };
    });
  }

  /// Generates a signed pre-key with a placeholder signature.
  ///
  /// The signature should be computed over the public key bytes using the
  /// identity private key. This synchronous version generates a random
  /// signature for compatibility — use [generateKeyPair] + [sign] for
  /// the real async flow with proper Ed25519 signatures.
  static Map<String, dynamic> generateSignedPreKey(int keyId) {
    return {
      'keyId': keyId,
      'publicKey': _randomBase64(32),
      'privateKey': _randomBase64(32),
      // Placeholder — real callers should use SignalProtocol.sign() to
      // produce a proper Ed25519 signature over the public key.
      'signature': _randomBase64(64),
    };
  }

  /// X25519 Diffie-Hellman key agreement.
  ///
  /// Computes a shared secret from our private key and their public key.
  /// The shared secret is 32 bytes and must be fed into HKDF before use
  /// as an encryption key — raw DH output is not uniformly distributed.
  static Future<List<int>> keyAgreement(
    String myPrivateKeyB64,
    String theirPublicKeyB64,
  ) async {
    final myPrivateBytes = base64Decode(myPrivateKeyB64);
    final theirPublicBytes = base64Decode(theirPublicKeyB64);

    final myKeyPair = await _x25519.newKeyPairFromSeed(myPrivateBytes);
    final theirPublicKey = SimplePublicKey(
      theirPublicBytes,
      type: KeyPairType.x25519,
    );

    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: myKeyPair,
      remotePublicKey: theirPublicKey,
    );
    return sharedSecret.extractBytes();
  }

  /// HKDF-SHA256 key derivation.
  ///
  /// Expands input key material into a derived key of [length] bytes.
  /// Used after X3DH to derive root + chain keys from concatenated DH
  /// outputs, and during the symmetric ratchet to derive message keys
  /// from chain keys.
  ///
  /// [salt] should be random for initial derivation, or the previous
  /// root key for ratchet steps. [info] provides domain separation
  /// (e.g. "msg-key" vs "chain-key") so the same input produces
  /// different outputs for different purposes.
  static Future<List<int>> deriveKey(
    List<int> inputKeyMaterial,
    List<int> salt,
    List<int> info,
    int length,
  ) async {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: length);
    final derivedKey = await hkdf.deriveKey(
      secretKey: SecretKey(inputKeyMaterial),
      nonce: salt,
      info: info,
    );
    return derivedKey.extractBytes();
  }

  /// Encrypts plaintext with AES-256-GCM.
  ///
  /// Returns [nonce (12 bytes)][ciphertext][GCM tag (16 bytes)].
  /// The nonce is randomly generated per message — reusing a nonce with
  /// the same key would completely break GCM's security guarantees.
  ///
  /// [aad] (additional authenticated data) is authenticated but not
  /// encrypted. The Double Ratchet passes the message header here so a
  /// tampered header (e.g. swapped ratchet key or message number) fails
  /// authentication even though the header itself travels in plaintext.
  static Future<Uint8List> encrypt(
    List<int> key,
    List<int> plaintext, {
    List<int> aad = const [],
  }) async {
    final secretKey = SecretKey(key);
    final secretBox =
        await aesGcm.encrypt(plaintext, secretKey: secretKey, aad: aad);
    return Uint8List.fromList([
      ...secretBox.nonce,
      ...secretBox.cipherText,
      ...secretBox.mac.bytes,
    ]);
  }

  /// Decrypts AES-256-GCM ciphertext.
  ///
  /// Expects the format produced by [encrypt]:
  /// [nonce (12 bytes)][ciphertext][GCM tag (16 bytes)].
  /// [aad] must match the value passed to [encrypt] byte-for-byte.
  /// Throws [SecretBoxAuthenticationError] if the ciphertext, tag, or
  /// AAD has been tampered with — GCM is authenticated encryption.
  static Future<List<int>> decrypt(
    List<int> key,
    Uint8List encrypted, {
    List<int> aad = const [],
  }) async {
    // AES-GCM nonce is always 12 bytes; GCM tag is always 16 bytes.
    final nonce = encrypted.sublist(0, 12);
    final ciphertext = encrypted.sublist(12, encrypted.length - 16);
    final mac = Mac(encrypted.sublist(encrypted.length - 16));

    final secretKey = SecretKey(key);
    final secretBox = SecretBox(ciphertext, nonce: nonce, mac: mac);
    return aesGcm.decrypt(secretBox, secretKey: secretKey, aad: aad);
  }

  /// HMAC-SHA256 — the KDF_CK primitive of the Double Ratchet.
  ///
  /// The Signal spec advances chain keys with constant-input HMAC instead
  /// of HKDF: messageKey = HMAC(chainKey, 0x01), nextChainKey =
  /// HMAC(chainKey, 0x02). The two constant bytes provide domain separation
  /// so a message key can never collide with a chain key.
  static Future<List<int>> hmacSha256(List<int> key, List<int> data) async {
    final mac = await Hmac.sha256().calculateMac(data, secretKey: SecretKey(key));
    return mac.bytes;
  }

  /// Produces a cryptographically secure random byte sequence as base64.
  static String _randomBase64(int byteLength) {
    final bytes = Uint8List(byteLength);
    for (var i = 0; i < byteLength; i++) {
      bytes[i] = _rng.nextInt(256);
    }
    return base64Encode(bytes);
  }
}
