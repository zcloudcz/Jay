import 'package:calltype/core/config/firebase_config.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

const _complete = {
  'FIREBASE_PROJECT_ID': 'jay-prod',
  'FIREBASE_MESSAGING_SENDER_ID': '1234567890',
  'FIREBASE_STORAGE_BUCKET': 'jay-prod.appspot.com',
  'FIREBASE_WEB_API_KEY': 'web-key',
  'FIREBASE_WEB_APP_ID': '1:1234567890:web:abc',
  'FIREBASE_WEB_AUTH_DOMAIN': 'jay-prod.firebaseapp.com',
  'FIREBASE_WEB_VAPID_KEY': 'vapid',
  'FIREBASE_ANDROID_API_KEY': 'android-key',
  'FIREBASE_ANDROID_APP_ID': '1:1234567890:android:def',
  'FIREBASE_APPLE_API_KEY': 'apple-key',
  'FIREBASE_IOS_APP_ID': '1:1234567890:ios:ghi',
  'FIREBASE_MACOS_APP_ID': '1:1234567890:ios:mac',
  'FIREBASE_APPLE_BUNDLE_ID': 'cz.zcloud.jay',
};

void main() {
  test('no defines -> null on every platform', () {
    for (final p in TargetPlatform.values) {
      expect(FirebaseConfig.fromDefines({}, platform: p, isWeb: false), isNull);
    }
    expect(
      FirebaseConfig.fromDefines(
        {},
        platform: TargetPlatform.android,
        isWeb: true,
      ),
      isNull,
    );
  });

  test('web uses the FIREBASE_WEB_* keys whatever the host OS', () {
    final o = FirebaseConfig.fromDefines(
      _complete,
      platform: TargetPlatform.macOS,
      isWeb: true,
    )!;
    expect(o.apiKey, 'web-key');
    expect(o.appId, '1:1234567890:web:abc');
    expect(o.authDomain, 'jay-prod.firebaseapp.com');
    expect(o.projectId, 'jay-prod');
    expect(o.messagingSenderId, '1234567890');
    expect(o.storageBucket, 'jay-prod.appspot.com');
  });

  test('android', () {
    final o = FirebaseConfig.fromDefines(
      _complete,
      platform: TargetPlatform.android,
      isWeb: false,
    )!;
    expect(o.apiKey, 'android-key');
    expect(o.appId, '1:1234567890:android:def');
    expect(o.iosBundleId, isNull);
  });

  test('iOS and macOS share the Apple key and bundle id', () {
    final ios = FirebaseConfig.fromDefines(
      _complete,
      platform: TargetPlatform.iOS,
      isWeb: false,
    )!;
    expect(ios.apiKey, 'apple-key');
    expect(ios.appId, '1:1234567890:ios:ghi');
    expect(ios.iosBundleId, 'cz.zcloud.jay');

    final mac = FirebaseConfig.fromDefines(
      _complete,
      platform: TargetPlatform.macOS,
      isWeb: false,
    )!;
    expect(mac.appId, '1:1234567890:ios:mac');
    expect(mac.iosBundleId, 'cz.zcloud.jay');
  });

  test('macOS without its own app id falls back to the iOS one', () {
    final d = Map.of(_complete)..remove('FIREBASE_MACOS_APP_ID');
    final mac = FirebaseConfig.fromDefines(
      d,
      platform: TargetPlatform.macOS,
      isWeb: false,
    )!;
    expect(mac.appId, '1:1234567890:ios:ghi');
  });

  test('windows and linux have no Firebase', () {
    for (final p in [TargetPlatform.windows, TargetPlatform.linux]) {
      expect(
        FirebaseConfig.fromDefines(_complete, platform: p, isWeb: false),
        isNull,
      );
    }
  });

  test('a missing or blank required value makes the config invalid', () {
    for (final key in [
      'FIREBASE_ANDROID_APP_ID',
      'FIREBASE_ANDROID_API_KEY',
      'FIREBASE_PROJECT_ID',
      'FIREBASE_MESSAGING_SENDER_ID',
    ]) {
      final missing = Map.of(_complete)..remove(key);
      final blank = Map.of(_complete)..[key] = '  ';
      for (final d in [missing, blank]) {
        expect(
          FirebaseConfig.fromDefines(
            d,
            platform: TargetPlatform.android,
            isWeb: false,
          ),
          isNull,
          reason: key,
        );
      }
    }
  });

  test('a test build has no dart-defines, so nothing is configured', () {
    expect(FirebaseConfig.currentPlatform, isNull);
    expect(FirebaseConfig.isConfigured, isFalse);
    expect(FirebaseConfig.webVapidKey, isNull);
  });
}
