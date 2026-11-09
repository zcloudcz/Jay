import 'package:flutter/foundation.dart';

import 'package:calltype_core/network/api_client.dart';
import '../calls/callkit_ring_platform.dart' show ringPushBackgroundHandler;
import '../../core/network/push_service.dart';
import '../../core/storage/secure_storage.dart';
import 'local_notifier.dart';
import 'notification_service.dart';
import 'plugin_local_notifier.dart';
import 'web_local_notifier.dart';
import 'web_platform.dart';
import 'web_push_provider.dart';

/// The local notifier of the running platform (spec section 2): the browser
/// API on the web, flutter_local_notifications on mobile and desktop.
LocalNotifier createLocalNotifier() {
  if (kIsWeb) return WebLocalNotifier();
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
    case TargetPlatform.linux:
      return PluginLocalNotifier();
    case TargetPlatform.fuchsia:
      return NoopLocalNotifier();
  }
}

/// The server push channel of the running platform, or null where there is
/// none (desktop: no OS push channel without a store app, spec N7).
PushProvider? createPushProvider(ApiClient apiClient) {
  if (kIsWeb) {
    return WebPlatform.instance.pushSupported
        ? WebPushProvider(apiClient: apiClient)
        : null;
  }
  return switch (defaultTargetPlatform) {
    // The background handler shows the full-screen call of a ring push
    // (call ringing spec, section 2, Android).
    TargetPlatform.android => FcmPushProvider(
      backgroundHandler: ringPushBackgroundHandler,
    ),
    // Native APNs token, not Firebase (spec section 2, iOS).
    TargetPlatform.iOS => ApnsPushProvider(),
    _ => null,
  };
}

/// Notification settings live next to the other device-local settings.
class SecureStoragePrefs implements NotificationPrefsStore {
  SecureStoragePrefs(this._storage);
  final SecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key);

  @override
  Future<void> write(String key, String value) => _storage.write(key, value);
}

/// Web: the tab is visible and focused. Elsewhere Flutter's lifecycle is
/// the whole truth (see the caller in main.dart).
bool get webDocumentFocused => !kIsWeb || WebPlatform.instance.documentFocused;
