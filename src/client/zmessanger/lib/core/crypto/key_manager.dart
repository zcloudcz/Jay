import '../storage/secure_storage.dart';
import 'signal_protocol.dart';

/// Manages the device's long-lived identity key pair.
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
///   2. The identity key must survive database resets / re-encryption
///   3. It keeps the attack surface minimal — only one key to protect
class KeyManager {
  KeyManager({required SecureStorage secureStorage})
      : _secureStorage = secureStorage;

  final SecureStorage _secureStorage;

  // Storage keys — prefixed to avoid collisions with other secure values.
  static const _publicKeyKey = 'zm_identity_public_key';
  static const _privateKeyKey = 'zm_identity_private_key';

  /// Returns the existing identity key pair, or generates and persists
  /// a new one if this is the first launch.
  ///
  /// The returned map has 'publicKey' and 'privateKey' as base64 strings.
  Future<Map<String, String>> getOrCreateIdentityKeyPair() async {
    final existingPublic = await _secureStorage.read(_publicKeyKey);
    final existingPrivate = await _secureStorage.read(_privateKeyKey);

    if (existingPublic != null && existingPrivate != null) {
      return {'publicKey': existingPublic, 'privateKey': existingPrivate};
    }

    // First launch — generate a new key pair and persist it.
    // This is the ONLY time keys are generated; after this they are
    // loaded from storage on every subsequent app start.
    final keyPair = SignalProtocol.generateIdentityKeyPair();

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
}
