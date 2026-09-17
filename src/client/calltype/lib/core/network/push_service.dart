import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'api_client.dart';

/// Observable state of the push subsystem, distinguished per K04 so the UI
/// (and Q01 acceptance) can tell "the user said no" apart from "this build
/// has no Firebase config" apart from "it's working".
enum PushStatus {
  /// Platform has no Firebase Messaging support (Windows/Linux desktop).
  unsupported,

  /// Firebase.initializeApp() or requestPermission() failed — no config
  /// files bundled, or the platform channel is unavailable.
  notConfigured,

  /// The user explicitly denied the notification permission prompt.
  permissionDenied,

  /// Token obtained and (attempted to be) registered with the backend.
  registered,
}

/// Thin seam around the static `FirebaseMessaging.instance` API so tests can
/// substitute a fake — the real SDK has no constructor to inject and talks to
/// platform channels that don't exist in `flutter test`.
abstract class PushMessagingClient {
  Future<void> initializeFirebase();
  Future<NotificationSettings> requestPermission();
  Future<String?> getToken();
  Stream<String> get onTokenRefresh;
  Stream<RemoteMessage> get onMessage;
  Stream<RemoteMessage> get onMessageOpenedApp;
}

class _FirebasePushMessagingClient implements PushMessagingClient {
  @override
  Future<void> initializeFirebase() => Firebase.initializeApp();

  @override
  Future<NotificationSettings> requestPermission() =>
      FirebaseMessaging.instance.requestPermission(alert: true, badge: true, sound: true);

  @override
  Future<String?> getToken() => FirebaseMessaging.instance.getToken();

  @override
  Stream<String> get onTokenRefresh => FirebaseMessaging.instance.onTokenRefresh;

  @override
  Stream<RemoteMessage> get onMessage => FirebaseMessaging.onMessage;

  @override
  Stream<RemoteMessage> get onMessageOpenedApp => FirebaseMessaging.onMessageOpenedApp;
}

/// Manages push notification token registration and incoming message handling.
///
/// On [initialize], this service:
///   1. Requests notification permissions (required on iOS, auto-granted on Android)
///   2. Retrieves the current FCM token from Firebase
///   3. Registers the token with the CallType backend via the API
///   4. Subscribes to token refresh events so the backend always has the latest token
///
/// Firebase project configuration files (google-services.json for Android,
/// GoogleService-Info.plist for iOS) must be in place at build time. Without them,
/// Firebase initialization will fail and push simply won't work — the app
/// continues to function normally without push via the store-and-forward queue.
///
/// This service sends data-only pushes (no notification body from the server).
/// The server knows nothing about message content due to E2E encryption, so
/// the client is responsible for displaying local notifications when a push
/// arrives.
class PushService {
  PushService(
    this._api,
    this._deviceId, {
    PushMessagingClient? messaging,
    this.onMessageReceived,
    this.onChannelPost,
    this.onNotificationOpened,
  }) : _messaging = messaging ?? _FirebasePushMessagingClient();

  final ApiClient _api;
  final String _deviceId;
  final PushMessagingClient _messaging;

  /// Called when a push arrives while the app is in the foreground.
  /// Per K04 the payload carries no plaintext — this is only a hook for the
  /// caller to trigger the existing inbox refresh, not to render content.
  final VoidCallback? onMessageReceived;

  /// Called instead of [onMessageReceived] for a `{type: "channel_post"}`
  /// push. Channels have no server-side queue and live outside the chat
  /// inbox, so the right reaction is a channels sync, not an inbox refresh.
  final VoidCallback? onChannelPost;

  /// Called when the user taps a notification (app was backgrounded/terminated).
  /// Per K04 this must route to the conversation list and the existing
  /// reconnect/replay path — never a new plaintext-carrying endpoint.
  final VoidCallback? onNotificationOpened;

  StreamSubscription<String>? _refreshSub;
  StreamSubscription<RemoteMessage>? _messageSub;
  StreamSubscription<RemoteMessage>? _openedSub;

  /// Last foreground messageId handled — guards against showing/handling the
  /// same event twice if FCM redelivers it (data-only messages have no
  /// dedup contract on the client the way visible notifications do).
  String? _lastHandledMessageId;

  PushStatus _status = PushStatus.notConfigured;
  PushStatus get status => _status;

  /// Request notification permissions and register the FCM token with the server.
  ///
  /// This is designed to be called fire-and-forget during app startup. Errors
  /// are caught internally — push is a best-effort feature and must never
  /// block the main app flow. Safe to call more than once: previous
  /// subscriptions are cancelled first so listeners never accumulate.
  Future<void> initialize() async {
    await _cancelSubscriptions();

    if (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux) {
      _status = PushStatus.unsupported;
      return;
    }

    try {
      await _messaging.initializeFirebase();

      // iOS requires an explicit permission prompt. On Android this is
      // auto-granted but calling requestPermission is harmless (returns
      // immediately with authorized status).
      final settings = await _messaging.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        _status = PushStatus.permissionDenied;
        return;
      }

      // Get the current FCM registration token. This token identifies
      // this app instance and is used by the server to target push messages.
      final token = await _messaging.getToken();
      if (token != null) {
        await _registerToken(token);
      }

      // FCM periodically rotates tokens (e.g. after app restore, OS update,
      // or manual token deletion). Listen for refreshes so the server always
      // has the current token — a stale token means silent push failures.
      _refreshSub = _messaging.onTokenRefresh.listen(_registerToken);

      // Foreground: FCM never shows a system notification itself, so this is
      // the only signal the app gets. Route it through onMessageReceived so
      // the caller can refresh the inbox rather than rendering push content.
      _messageSub = _messaging.onMessage.listen(_handleForegroundMessage);

      // User tapped a background/terminated notification — go to the
      // conversation list and let the existing reconnect/replay fetch it.
      _openedSub = _messaging.onMessageOpenedApp.listen((_) => onNotificationOpened?.call());

      _status = PushStatus.registered;
    } catch (e) {
      // Firebase not configured (missing config files / no platform channel)
      // — push won't work but the app is fully functional without it.
      // Messages are still delivered via the store-and-forward queue.
      _status = PushStatus.notConfigured;
    }
  }

  Future<void> dispose() async {
    await _cancelSubscriptions();
  }

  Future<void> _cancelSubscriptions() async {
    await _refreshSub?.cancel();
    await _messageSub?.cancel();
    await _openedSub?.cancel();
    _refreshSub = null;
    _messageSub = null;
    _openedSub = null;
  }

  void _handleForegroundMessage(RemoteMessage message) {
    if (message.messageId != null && message.messageId == _lastHandledMessageId) {
      return;
    }
    _lastHandledMessageId = message.messageId;
    if (message.data['type'] == 'channel_post') {
      onChannelPost?.call();
    } else {
      onMessageReceived?.call();
    }
  }

  /// Sends the FCM token to the backend so it can send push notifications
  /// to this device when messages arrive while the app is not connected.
  Future<void> _registerToken(String token) async {
    try {
      await _api.updatePushToken(
        deviceId: _deviceId,
        token: token,
        // Android and Web use FCM natively. iOS uses APNs under the hood
        // but Firebase abstracts it — the server-side distinction matters
        // for the delivery mechanism.
        platform: 'fcm',
      );
    } catch (e) {
      // Non-fatal — push just won't work until the next token refresh
      // triggers another registration attempt. The store-and-forward
      // queue guarantees message delivery regardless.
    }
  }
}
