import 'package:flutter/foundation.dart';

import '../../core/crypto/key_manager.dart';
import '../../core/network/api_client.dart';
import '../../core/storage/secure_storage.dart';

/// Drives the first-launch onboarding flow: key generation, device
/// registration with the server, and local persistence of the device ID.
///
/// Uses [ChangeNotifier] so the onboarding screen can rebuild reactively
/// as the async registration progresses through loading → success / error.
class OnboardingController extends ChangeNotifier {
  OnboardingController({
    required ApiClient apiClient,
    required SecureStorage secureStorage,
    required KeyManager keyManager,
  })  : _apiClient = apiClient,
        _secureStorage = secureStorage,
        _keyManager = keyManager;

  final ApiClient _apiClient;
  final SecureStorage _secureStorage;
  final KeyManager _keyManager;

  String? _deviceId;
  String? _userHandle;
  bool _isLoading = false;
  String? _error;

  /// The server-assigned device UUID, available after successful registration.
  String? get deviceId => _deviceId;

  /// Human-readable handle (e.g. CT-A1B2-C3D4) for display and sharing.
  String? get userHandle => _userHandle;

  /// True while the registration HTTP call is in flight.
  bool get isLoading => _isLoading;

  /// Error message from the last failed registration attempt, or null.
  String? get error => _error;

  /// Data encoded into the QR code for contact exchange.
  ///
  /// Contains both the device ID (for API lookups) and the user handle
  /// (for human display) so the scanning device has everything it needs
  /// to initiate a key exchange without a second network call.
  String? get qrData {
    if (_deviceId == null || _userHandle == null) return null;
    return 'zm://$_deviceId/$_userHandle';
  }

  /// Starts the device registration flow.
  ///
  /// Generates the device's REAL cryptographic key material via [KeyManager]
  /// (X25519 identity key pair, signed pre-key pair, and a batch of one-time
  /// pre-key pairs), uploads the PUBLIC halves to the server, and persists
  /// the resulting device ID locally. The private halves never leave the
  /// device — they stay in platform-secure storage, where the session
  /// manager finds them when a peer initiates an E2E session with us.
  Future<void> register() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final identityKey = await _keyManager.getPublicIdentityKey();
      final signedPreKey = await _keyManager.getOrCreateSignedPreKey();
      final oneTimePreKeys = await _keyManager.getOrCreateOneTimePreKeys();

      final result = await _apiClient.registerDevice(
        identityKey: identityKey,
        signedPreKey: signedPreKey['publicKey'] as String,
        // Upload only keyId + public half — see KeyManager docs.
        oneTimePreKeys: [
          for (final preKey in oneTimePreKeys)
            {
              'keyId': preKey['keyId'],
              'publicKey': preKey['publicKey'],
            },
        ],
      );

      _deviceId = result['deviceId'] as String;
      _userHandle = result['userHandle'] as String;

      // Persist device ID so the app knows it's provisioned on next launch.
      await _secureStorage.setDeviceId(_deviceId!);

      // Persist the device secret — the server returns it EXACTLY ONCE
      // (only its hash is stored server-side). It is the credential
      // AuthService exchanges for JWTs on every API call and SignalR connect.
      final deviceSecret = result['deviceSecret'] as String?;
      if (deviceSecret != null) {
        await _secureStorage.setDeviceSecret(deviceSecret);
      }

      _isLoading = false;
      notifyListeners();
    } catch (e) {
      _isLoading = false;
      _error = e.toString();
      notifyListeners();
    }
  }
}
