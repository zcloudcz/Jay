import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Dart-side wrapper for the native libsignal FFI bridge.
///
/// PLACEHOLDER IMPLEMENTATION: All methods generate random keys instead of
/// calling the Rust FFI. This lets the rest of the app develop and test
/// against a stable API surface while the native bridge is compiled and
/// linked per platform.
///
/// Real implementation will:
///   - Load the native library via `dart:ffi` (mobile) or JS interop (web)
///   - Call `signal_generate_identity_key_pair()` etc. from lib.rs
///   - Parse the returned JSON into Dart types
///   - Free the native string via `signal_free_string()`
class SignalProtocol {
  SignalProtocol._();

  /// Whether the native library has been loaded and initialized.
  ///
  /// Always true in this placeholder — the real implementation sets this
  /// to true only after successfully loading the .so / .dylib / .wasm.
  static bool isInitialized = true;

  static final _rng = Random.secure();

  /// Generates a placeholder identity key pair (random 32-byte keys).
  ///
  /// Returns a map with 'publicKey' and 'privateKey' as base64 strings.
  /// The real implementation calls native `signal_generate_identity_key_pair()`.
  static Map<String, String> generateIdentityKeyPair() {
    return {
      'publicKey': _randomBase64(32),
      'privateKey': _randomBase64(32),
    };
  }

  /// Generates a batch of placeholder pre-keys.
  ///
  /// Each entry contains 'keyId', 'publicKey', and 'privateKey'.
  /// The real implementation calls native `signal_generate_pre_keys()`.
  static List<Map<String, dynamic>> generatePreKeys(int startId, int count) {
    return List.generate(count, (i) {
      return {
        'keyId': startId + i,
        'publicKey': _randomBase64(32),
        'privateKey': _randomBase64(32),
      };
    });
  }

  /// Generates a placeholder signed pre-key.
  ///
  /// In the real implementation this key is signed with the identity
  /// private key so the receiver can verify it wasn't tampered with
  /// during transit. The placeholder skips signing.
  static Map<String, dynamic> generateSignedPreKey(int keyId) {
    return {
      'keyId': keyId,
      'publicKey': _randomBase64(32),
      'privateKey': _randomBase64(32),
      // Placeholder signature — real implementation uses Ed25519 over
      // the serialized public key, signed with the identity private key.
      'signature': _randomBase64(64),
    };
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
