import 'dart:convert';

import '../storage/secure_storage.dart';
import 'signal_protocol.dart';

/// Manages the device's long-lived cryptographic key material:
/// the identity key pair, the signed pre-key pair, and the batch of
/// one-time pre-key pairs used by peers to initiate X3DH sessions.
///
/// The identity key pair is the root of trust in the Signal Protocol.
/// It is generated once on first launch and persisted in platform-secure
/// storage (Keychain / EncryptedSharedPreferences). Losing this key pair
/// means losing all existing sessions — peers would see a "safety number
/// changed" warning, similar to WhatsApp/Signal.
///
/// Keys are stored as base64-encoded strings in SecureStorage rather than
/// in the SQLite database because:
///   1. SecureStorage is hardware-backed on modern devices (Keystore / SE)
///   2. The keys must survive database resets / re-encryption
///   3. It keeps the attack surface minimal
///
/// PRIVATE halves of the signed pre-key and one-time pre-keys stay here on
/// the device; only the PUBLIC halves are uploaded to the server during
/// registration. When a peer initiates a session, their first message tells
/// us which one-time pre-key they consumed (by keyId) so we can look up the
/// matching private key for our side of the X3DH computation.
class KeyManager {
  KeyManager({required SecureStorage secureStorage})
      : _secureStorage = secureStorage;

  final SecureStorage _secureStorage;

  // Storage keys — prefixed to avoid collisions with other secure values.
  static const _publicKeyKey = 'ct_identity_public_key';
  static const _privateKeyKey = 'ct_identity_private_key';
  static const _signedPreKeyKey = 'ct_signed_prekey';
  static const _oneTimePreKeysKey = 'ct_one_time_prekeys';

  /// How many one-time pre-keys to generate for the initial upload.
  /// Signal recommends ~100: each is consumed by one incoming session
  /// initiation, and a large batch delays the need to replenish.
  static const initialOneTimePreKeyCount = 100;

  /// Returns the existing identity key pair, or generates and persists
  /// a new one if this is the first launch.
  ///
  /// Uses real X25519 key generation via [SignalProtocol.generateKeyPair].
  /// The returned map has 'publicKey' and 'privateKey' as base64 strings
  /// representing a valid X25519 key pair where the public key is the
  /// Curve25519 point derived from the private seed.
  Future<Map<String, String>> getOrCreateIdentityKeyPair() async {
    final existingPublic = await _secureStorage.read(_publicKeyKey);
    final existingPrivate = await _secureStorage.read(_privateKeyKey);

    if (existingPublic != null && existingPrivate != null) {
      return {'publicKey': existingPublic, 'privateKey': existingPrivate};
    }

    // First launch — generate a real X25519 key pair and persist it.
    // This is the ONLY time keys are generated; after this they are
    // loaded from storage on every subsequent app start.
    final keyPair = await SignalProtocol.generateKeyPair();

    await _secureStorage.write(_publicKeyKey, keyPair['publicKey']!);
    await _secureStorage.write(_privateKeyKey, keyPair['privateKey']!);

    return keyPair;
  }

  /// Convenience method to get just the public identity key (base64).
  ///
  /// Used when registering the device with the server or when a peer
  /// requests our key bundle for X3DH.
  Future<String> getPublicIdentityKey() async {
    final keyPair = await getOrCreateIdentityKeyPair();
    return keyPair['publicKey']!;
  }

  /// Returns the private identity key (base64).
  ///
  /// Needed by the session manager to perform the X3DH DH computations.
  /// Keep the private key in memory only as long as needed — do not
  /// cache it in a field.
  Future<String> getPrivateIdentityKey() async {
    final keyPair = await getOrCreateIdentityKeyPair();
    return keyPair['privateKey']!;
  }

  // -- Signed pre-key ---------------------------------------------------------

  /// Returns the device's signed pre-key pair, generating and persisting
  /// one on first call.
  ///
  /// The signed pre-key doubles as the responder's INITIAL RATCHET KEY in
  /// the Double Ratchet: the session initiator uses our signed pre-key as
  /// the first remote ratchet public key, so we must keep the private half
  /// to perform the first DH ratchet step when their message arrives.
  ///
  /// Returned map: { keyId: int, publicKey: b64, privateKey: b64 }.
  Future<Map<String, dynamic>> getOrCreateSignedPreKey() async {
    final existing = await _secureStorage.read(_signedPreKeyKey);
    if (existing != null) {
      return jsonDecode(existing) as Map<String, dynamic>;
    }

    final keyPair = await SignalProtocol.generateKeyPair();
    final signedPreKey = <String, dynamic>{
      // keyId 1 — only one signed pre-key per device for now. Rotation
      // (periodically replacing the SPK) is a future hardening step.
      'keyId': 1,
      'publicKey': keyPair['publicKey']!,
      'privateKey': keyPair['privateKey']!,
    };

    await _secureStorage.write(_signedPreKeyKey, jsonEncode(signedPreKey));
    return signedPreKey;
  }

  // -- One-time pre-keys ------------------------------------------------------

  /// Returns the batch of one-time pre-key pairs, generating
  /// [initialOneTimePreKeyCount] of them on first call.
  ///
  /// Returned list items: { keyId: int, publicKey: b64, privateKey: b64 }.
  /// The full list (including private halves) is persisted locally; the
  /// caller uploads only keyId + publicKey to the server.
  Future<List<Map<String, dynamic>>> getOrCreateOneTimePreKeys() async {
    final existing = await _secureStorage.read(_oneTimePreKeysKey);
    if (existing != null) {
      return (jsonDecode(existing) as List).cast<Map<String, dynamic>>();
    }

    final preKeys = <Map<String, dynamic>>[];
    for (var i = 0; i < initialOneTimePreKeyCount; i++) {
      final keyPair = await SignalProtocol.generateKeyPair();
      preKeys.add({
        // keyIds start at 1 — keyId 0 is reserved as "no one-time key used".
        'keyId': i + 1,
        'publicKey': keyPair['publicKey']!,
        'privateKey': keyPair['privateKey']!,
      });
    }

    await _secureStorage.write(_oneTimePreKeysKey, jsonEncode(preKeys));
    return preKeys;
  }

  /// Consumes the one-time pre-key with the given id: returns its private
  /// key (base64) and DELETES it from storage, or returns null if unknown.
  ///
  /// Deletion is the point of "one-time" keys: a replayed initial message
  /// referencing an already-consumed keyId cannot re-establish the session,
  /// which is X3DH's replay protection.
  Future<String?> consumeOneTimePreKey(int keyId) async {
    final stored = await _secureStorage.read(_oneTimePreKeysKey);
    if (stored == null) return null;

    final preKeys = (jsonDecode(stored) as List).cast<Map<String, dynamic>>();
    final index = preKeys.indexWhere((k) => k['keyId'] == keyId);
    if (index < 0) return null;

    final privateKey = preKeys[index]['privateKey'] as String;
    preKeys.removeAt(index);
    await _secureStorage.write(_oneTimePreKeysKey, jsonEncode(preKeys));

    return privateKey;
  }
}
