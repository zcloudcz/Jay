import 'package:flutter/foundation.dart';

import 'package:calltype_core/crypto/key_manager.dart';
import 'package:calltype_core/network/api_client.dart';
import '../../core/storage/secure_storage.dart';
import '../devices/link_ux.dart';

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
    this.onRegistered,
  }) : _apiClient = apiClient,
       _secureStorage = secureStorage,
       _keyManager = keyManager;

  final ApiClient _apiClient;
  final SecureStorage _secureStorage;
  final KeyManager _keyManager;
  final Future<void> Function(String deviceId)? onRegistered;
  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  String? _deviceId;
  String? _userHandle;
  bool _isLoading = false;
  String? _error;

  /// The server-assigned device UUID, available after successful registration.
  String? get deviceId => _deviceId;

  /// Human-readable handle (e.g. CT-A1B2-C3D4) for display and sharing.
  String? get userHandle => _userHandle;

  bool _linkMode = false;

  /// The device is being set up to be linked to a phone (link UX, A1): the
  /// screen shows the link code, never this device's own handle.
  bool get linkMode => _linkMode;

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
    return 'ct://$_deviceId/$_userHandle';
  }

  /// Link path (link UX, A1): registers this device silently if it is not
  /// registered yet (the link code needs a device id and keys) and marks it as
  /// waiting for the phone ([linkPendingKey]). An already registered device,
  /// e.g. one just reset by "disconnect and link", skips the registration.
  Future<void> startLinking() async {
    _linkMode = true;
    _error = null;
    notifyListeners();
    try {
      await _secureStorage.write(linkPendingKey, '1');
    } catch (_) {
      // Only the reload protection is lost.
    }
    final id = await _secureStorage.getDeviceId();
    final secret = await _secureStorage.getDeviceSecret();
    if (id != null && secret != null) {
      _deviceId = id;
      notifyListeners();
      return;
    }
    await register();
  }

  /// "I don't have Jay on a phone, start here": a standalone identity, as the
  /// mobile onboarding creates it. Reuses a registration the link path already
  /// made (or is making) instead of creating a second device.
  Future<void> startStandalone() async {
    _linkMode = false;
    _error = null;
    notifyListeners();
    try {
      await _secureStorage.delete(linkPendingKey);
    } catch (_) {}
    if (_isLoading) return; // The running registration shows the identity.
    if (_deviceId == null) {
      await register();
      return;
    }
    _userHandle ??= await _secureStorage.read('ct_user_handle') ?? _deviceId;
    notifyListeners();
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
    if (_isLoading) return;
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final identityKey = await _keyManager.getPublicIdentityKey();
      final signedPreKey = await _keyManager.getOrCreateSignedPreKey();
      final signedBundle = await _keyManager.getSignedIdentityBundle();
      final oneTimePreKeys = await _keyManager.getOrCreateOneTimePreKeys();

      final result = await _apiClient.registerDevice(
        identityKey: identityKey,
        signedPreKey: signedPreKey['publicKey'] as String,
        signingKey: signedBundle['signingKey'],
        signature: signedBundle['signature'],
        // Upload only keyId + public half — see KeyManager docs.
        oneTimePreKeys: [
          for (final preKey in oneTimePreKeys)
            {'keyId': preKey['keyId'], 'publicKey': preKey['publicKey']},
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
      await _secureStorage.write('ct_user_handle', _userHandle!);
      await onRegistered?.call(_deviceId!);

      _isLoading = false;
      notifyListeners();
    } catch (e) {
      _isLoading = false;
      _error = e.toString();
      notifyListeners();
    }
  }
}
