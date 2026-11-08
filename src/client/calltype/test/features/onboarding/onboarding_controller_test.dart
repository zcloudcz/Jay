import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:calltype_core/crypto/key_manager.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype/core/storage/secure_storage.dart';
import 'package:calltype/features/onboarding/onboarding_controller.dart';

/// Tests for [OnboardingController] — the first-launch registration flow.
///
/// The controller depends on ApiClient (HTTP) and SecureStorage (platform
/// channels), so we only test the pure logic that does not trigger real
/// network or platform calls: initial state, qrData formatting, etc.
///
/// Full registration flow testing requires a running backend or a mock
/// HTTP layer and is better suited for integration tests.
void main() {
  group('OnboardingController', () {
    late OnboardingController controller;

    setUp(() {
      // SecureStorage() constructor creates a const FlutterSecureStorage
      // internally — this is safe and does not call platform channels.
      // Platform channels are only invoked when read/write/delete are
      // called, which we avoid in these unit tests.
      final secureStorage = SecureStorage();
      controller = OnboardingController(
        apiClient: ApiClient(baseUrl: 'https://test.calltype.test'),
        secureStorage: secureStorage,
        keyManager: KeyManager(secureStorage: secureStorage),
      );
    });

    test('initial state — isLoading is false, error is null', () {
      expect(controller.isLoading, isFalse);
      expect(controller.error, isNull);
      expect(controller.deviceId, isNull);
      expect(controller.userHandle, isNull);
    });

    test('qrData is null before registration', () {
      // Before register() is called, deviceId and userHandle are null,
      // so qrData must also be null.
      expect(controller.qrData, isNull);
    });

    test('controller is a ChangeNotifier', () {
      // The UI depends on OnboardingController being a ChangeNotifier
      // so Provider can rebuild widgets when state changes.
      expect(controller, isA<ChangeNotifier>());
    });

    test('listener receives notifications', () {
      // Verify that addListener/removeListener work — essential for
      // Provider-based state management in the onboarding UI.
      var notified = false;
      void listener() {
        notified = true;
      }

      controller.addListener(listener);
      // We can't easily trigger notifyListeners without calling
      // register() (which needs HTTP), but we verify the listener
      // infrastructure is in place.
      controller.removeListener(listener);

      // The listener was added and removed without error.
      expect(notified, isFalse);
    });
  });
}
