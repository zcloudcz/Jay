import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// Firebase client options come from `--dart-define-from-file` at build time
/// (see .github/scripts/firebase-config.sh, stream P3b). They are public
/// identifiers, never secrets, but are kept out of git so forks and dev
/// builds cannot hit our project.
///
/// Contract X0-P6 (docs/superpowers/plans/2026-09-29-gap-platform.md §4); the
/// dart-define key names below are frozen. An empty value means "not set".
abstract final class FirebaseConfig {
  // Every key must be read with a *const* String.fromEnvironment — the
  // compiler only substitutes dart-defines into const expressions, so a
  // lookup by computed name would always yield ''.
  static const Map<String, String> _defines = {
    'FIREBASE_PROJECT_ID': String.fromEnvironment('FIREBASE_PROJECT_ID'),
    'FIREBASE_MESSAGING_SENDER_ID': String.fromEnvironment(
      'FIREBASE_MESSAGING_SENDER_ID',
    ),
    'FIREBASE_STORAGE_BUCKET': String.fromEnvironment(
      'FIREBASE_STORAGE_BUCKET',
    ),
    'FIREBASE_WEB_API_KEY': String.fromEnvironment('FIREBASE_WEB_API_KEY'),
    'FIREBASE_WEB_APP_ID': String.fromEnvironment('FIREBASE_WEB_APP_ID'),
    'FIREBASE_WEB_AUTH_DOMAIN': String.fromEnvironment(
      'FIREBASE_WEB_AUTH_DOMAIN',
    ),
    'FIREBASE_WEB_VAPID_KEY': String.fromEnvironment('FIREBASE_WEB_VAPID_KEY'),
    'FIREBASE_ANDROID_API_KEY': String.fromEnvironment(
      'FIREBASE_ANDROID_API_KEY',
    ),
    'FIREBASE_ANDROID_APP_ID': String.fromEnvironment(
      'FIREBASE_ANDROID_APP_ID',
    ),
    'FIREBASE_APPLE_API_KEY': String.fromEnvironment('FIREBASE_APPLE_API_KEY'),
    'FIREBASE_IOS_APP_ID': String.fromEnvironment('FIREBASE_IOS_APP_ID'),
    'FIREBASE_MACOS_APP_ID': String.fromEnvironment('FIREBASE_MACOS_APP_ID'),
    'FIREBASE_APPLE_BUNDLE_ID': String.fromEnvironment(
      'FIREBASE_APPLE_BUNDLE_ID',
    ),
  };

  /// Pure mapping from dart-define values to [FirebaseOptions], unit-testable
  /// without dart-defines. Returns null when the platform has no Firebase
  /// support in this app (Windows, Linux) or when any required value
  /// (apiKey, appId, messagingSenderId, projectId) is missing — an incomplete
  /// config must not pretend to be valid, it would only fail later and
  /// less clearly inside the SDK.
  static FirebaseOptions? fromDefines(
    Map<String, String> d, {
    required TargetPlatform platform,
    required bool isWeb,
  }) {
    String? v(String key) {
      final value = d[key]?.trim();
      return (value == null || value.isEmpty) ? null : value;
    }

    final projectId = v('FIREBASE_PROJECT_ID');
    final senderId = v('FIREBASE_MESSAGING_SENDER_ID');
    final storageBucket = v('FIREBASE_STORAGE_BUCKET');

    final String? apiKey;
    final String? appId;
    String? authDomain;
    String? iosBundleId;
    if (isWeb) {
      apiKey = v('FIREBASE_WEB_API_KEY');
      appId = v('FIREBASE_WEB_APP_ID');
      authDomain = v('FIREBASE_WEB_AUTH_DOMAIN');
    } else {
      switch (platform) {
        case TargetPlatform.android:
          apiKey = v('FIREBASE_ANDROID_API_KEY');
          appId = v('FIREBASE_ANDROID_APP_ID');
        case TargetPlatform.iOS:
          apiKey = v('FIREBASE_APPLE_API_KEY');
          appId = v('FIREBASE_IOS_APP_ID');
          iosBundleId = v('FIREBASE_APPLE_BUNDLE_ID');
        case TargetPlatform.macOS:
          apiKey = v('FIREBASE_APPLE_API_KEY');
          // One Firebase Apple app may serve both iOS and macOS, so a missing
          // macOS app id falls back to the iOS one.
          appId = v('FIREBASE_MACOS_APP_ID') ?? v('FIREBASE_IOS_APP_ID');
          iosBundleId = v('FIREBASE_APPLE_BUNDLE_ID');
        case TargetPlatform.windows:
        case TargetPlatform.linux:
        case TargetPlatform.fuchsia:
          return null;
      }
    }

    if (apiKey == null ||
        appId == null ||
        senderId == null ||
        projectId == null) {
      return null;
    }
    return FirebaseOptions(
      apiKey: apiKey,
      appId: appId,
      messagingSenderId: senderId,
      projectId: projectId,
      storageBucket: storageBucket,
      authDomain: authDomain,
      iosBundleId: iosBundleId,
    );
  }

  /// Options for the running platform, or null when this build has no config
  /// (dev, CI sanity, Windows, Linux). Callers treat null as
  /// PushStatus.notConfigured.
  static FirebaseOptions? get currentPlatform =>
      fromDefines(_defines, platform: defaultTargetPlatform, isWeb: kIsWeb);

  /// Web push VAPID public key (FirebaseMessaging.getToken(vapidKey:)), or null.
  static String? get webVapidKey {
    final key = _defines['FIREBASE_WEB_VAPID_KEY']!.trim();
    return key.isEmpty ? null : key;
  }

  static bool get isConfigured => currentPlatform != null;

  /// Initializes the default Firebase app with the build's options, if this
  /// build has any. Without options nothing happens and the existing
  /// PushService path (`Firebase.initializeApp()` from native config files,
  /// else notConfigured) behaves exactly as before.
  ///
  /// Never throws: push is best-effort and must not break start-up.
  static Future<void> initializeIfConfigured() async {
    final options = currentPlatform;
    if (options == null) return;
    try {
      await Firebase.initializeApp(options: options);
    } catch (e) {
      debugPrint('Firebase init with build options failed: $e');
    }
  }
}
