import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

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
  })  : _apiClient = apiClient,
        _secureStorage = secureStorage;

  final ApiClient _apiClient;
  final SecureStorage _secureStorage;

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
  /// Generates placeholder cryptographic keys (random 32-byte base64
  /// strings — real Signal Protocol keys come in Phase 3), uploads them
  /// to the server, and persists the resulting device ID locally.
  ///
  /// The 100 one-time pre-keys follow the Signal Protocol recommendation
  /// for initial key upload — the server hands one out to each peer that
  /// wants to start a session, so a large batch reduces how often we need
  /// to replenish.
  Future<void> register() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final identityKey = _generatePlaceholderKey();
      final signedPreKey = _generatePlaceholderKey();

      // Generate 100 one-time pre-keys as recommended by Signal Protocol.
      // Each key is consumed by a single X3DH handshake, so we upload a
      // large initial batch to avoid immediate replenishment.
      final oneTimePreKeys = List.generate(100, (_) => _generatePlaceholderKey());

      final result = await _apiClient.registerDevice(
        identityKey: identityKey,
        signedPreKey: signedPreKey,
        oneTimePreKeys: oneTimePreKeys,
      );

      _deviceId = result['deviceId'] as String;
      _userHandle = result['userHandle'] as String;

      // Persist device ID so the app knows it's provisioned on next launch.
      await _secureStorage.setDeviceId(_deviceId!);

      _isLoading = false;
      notifyListeners();
    } catch (e) {
      _isLoading = false;
      _error = e.toString();
      notifyListeners();
    }
  }

  /// Generates a random 32-byte base64-encoded string as a placeholder key.
  ///
  /// These are NOT real cryptographic keys — they exist solely to exercise
  /// the registration API and key upload flow. Phase 3 replaces this with
  /// actual libsignal key generation.
  static String _generatePlaceholderKey() {
    final rng = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    return base64Encode(bytes);
  }
}
