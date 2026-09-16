import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'api_client.dart';

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
  PushService(this._api, this._deviceId);

  final ApiClient _api;
  final String _deviceId;
  StreamSubscription<String>? _refresh;

  /// Request notification permissions and register the FCM token with the server.
  ///
  /// This is designed to be called fire-and-forget during app startup. Errors
  /// are caught internally — push is a best-effort feature and must never
  /// block the main app flow.
  Future<void> initialize() async {
    try {
      if (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux) {
        return;
      }
      await Firebase.initializeApp();
      final messaging = FirebaseMessaging.instance;
      // iOS requires an explicit permission prompt. On Android this is
      // auto-granted but calling requestPermission is harmless (returns
      // immediately with authorized status).
      await messaging.requestPermission(alert: true, badge: true, sound: true);

      // Get the current FCM registration token. This token identifies
      // this app instance and is used by the server to target push messages.
      final token = await messaging.getToken();
      if (token != null) {
        await _registerToken(token);
      }

      // FCM periodically rotates tokens (e.g. after app restore, OS update,
      // or manual token deletion). Listen for refreshes so the server always
      // has the current token — a stale token means silent push failures.
      await _refresh?.cancel();
      _refresh = messaging.onTokenRefresh.listen(_registerToken);
    } catch (e) {
      // Firebase not configured or permissions denied — push won't work
      // but the app is fully functional without it. Messages are still
      // delivered via the store-and-forward queue on next SignalR connect.
    }
  }

  Future<void> dispose() async {
    await _refresh?.cancel();
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
