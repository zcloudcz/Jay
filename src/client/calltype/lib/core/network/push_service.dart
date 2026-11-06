import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/services.dart';

import 'api_client.dart';

/// Observable state of the push subsystem, distinguished per K04 so the UI
/// can tell "the user said no" apart from "this build has no push config"
/// apart from "it's working".
enum PushStatus {
  /// Not registered yet (or unregistered because notifications are off).
  idle,

  /// The platform has no server push channel (Windows/Linux/macOS desktop:
  /// local notifications only, spec section 2).
  unsupported,

  /// The push provider is missing: no google-services.json in the Android
  /// build, no aps-environment entitlement (simulator), Web Push not
  /// configured on the server, or the browser lacks Push.
  notConfigured,

  /// The user denied the notification permission.
  permissionDenied,

  /// Token obtained and registered with the backend.
  registered,
}

/// Thrown by a [PushProvider] that cannot produce a token.
class PushUnavailable implements Exception {
  const PushUnavailable(this.status, [this.detail]);
  final PushStatus status;
  final Object? detail;
  @override
  String toString() => 'PushUnavailable($status, $detail)';
}

/// One server push channel (contract 1.1 `platform`). The data maps carry
/// the contract 1.3 keys `type`, `conversationId`, `v`.
abstract class PushProvider {
  /// `fcm`, `apns` or `webpush`.
  String get platform;

  /// The token for `PUT /devices/{id}/push-token`. Throws [PushUnavailable].
  /// The notification permission is already granted when this is called.
  Future<String> obtainToken();

  /// New tokens the platform issued on its own (FCM rotation, APNs change).
  Stream<String> get tokenRefresh;

  /// A server push the user tapped while the app was running.
  Stream<Map<String, String>> get opened;

  /// The server push whose tap launched the app, once.
  Future<Map<String, String>?> takeInitialOpened();

  /// Pushes delivered while the app is in the foreground (FCM only; the OS
  /// shows APNs / Web Push itself).
  Stream<Map<String, String>> get foreground;

  /// Drops the local token / subscription after the server forgot it.
  Future<void> release();
}

/// Registers this device's push token with the server and relays what the
/// provider reports. Push is best effort: nothing here may throw into the
/// app, messages always arrive through the store-and-forward queue anyway.
class PushService {
  PushService(
    this._api,
    this._deviceId, {
    required PushProvider provider,
    String? Function()? locale,
    this.onForegroundPush,
    this.onOpened,
  }) : _provider = provider,
       _locale = locale ?? (() => null);

  final ApiClient _api;
  final String _deviceId;
  final PushProvider _provider;
  final String? Function() _locale;

  /// A push that arrived while the app runs (e.g. `channel_post` -> sync).
  final void Function(Map<String, String> data)? onForegroundPush;

  /// The user tapped a server push (also the one that launched the app).
  final void Function(Map<String, String> data)? onOpened;

  final _subscriptions = <StreamSubscription<Object?>>[];
  bool _initialTaken = false;
  PushStatus _status = PushStatus.idle;
  PushStatus get status => _status;

  String get deviceId => _deviceId;
  String get platform => _provider.platform;

  /// Obtains the token and registers it. Safe to call again (every
  /// reconnect does, so a failed PUT is retried): previous listeners are
  /// cancelled first so they never accumulate.
  Future<PushStatus> register() async {
    await _cancelSubscriptions();
    final String token;
    try {
      token = await _provider.obtainToken();
    } on PushUnavailable catch (e) {
      return _status = e.status;
    } catch (_) {
      return _status = PushStatus.notConfigured;
    }
    await _put(token);
    _subscriptions
      ..add(_provider.tokenRefresh.listen(_put))
      ..add(_provider.foreground.listen((data) => onForegroundPush?.call(data)))
      ..add(_provider.opened.listen((data) => onOpened?.call(data)));
    // The launching tap is handled once per app run, not on every reconnect.
    if (!_initialTaken) {
      _initialTaken = true;
      try {
        final initial = await _provider.takeInitialOpened();
        if (initial != null) onOpened?.call(initial);
      } catch (_) {}
    }
    return _status = PushStatus.registered;
  }

  /// Notifications turned off: the server forgets the token (DELETE), then
  /// the platform subscription is dropped. Best effort, never throws.
  Future<void> unregister() async {
    await _cancelSubscriptions();
    try {
      await _api.deletePushToken(_deviceId);
    } catch (_) {
      // Offline: the server keeps the token until the next registration or
      // a provider reports it stale. Turning it on again re-registers.
    }
    try {
      await _provider.release();
    } catch (_) {}
    _status = PushStatus.idle;
  }

  Future<void> dispose() => _cancelSubscriptions();

  Future<void> _cancelSubscriptions() async {
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
  }

  Future<void> _put(String token) async {
    try {
      await _api.updatePushToken(
        deviceId: _deviceId,
        token: token,
        platform: _provider.platform,
        locale: _locale(),
      );
    } catch (_) {
      // Non-fatal: the next reconnect or token refresh registers again.
    }
  }
}

// -- FCM (Android) ------------------------------------------------------------

/// Thin seam around the static `FirebaseMessaging.instance` API so tests can
/// substitute a fake: the real SDK has no constructor to inject and talks to
/// platform channels that don't exist in `flutter test`.
abstract class PushMessagingClient {
  Future<void> initializeFirebase();
  Future<String?> getToken();
  Future<void> deleteToken();
  Stream<String> get onTokenRefresh;
  Stream<RemoteMessage> get onMessage;
  Stream<RemoteMessage> get onMessageOpenedApp;
  Future<RemoteMessage?> getInitialMessage();
}

class FirebasePushMessagingClient implements PushMessagingClient {
  @override
  Future<void> initializeFirebase() => Firebase.initializeApp();

  @override
  Future<String?> getToken() => FirebaseMessaging.instance.getToken();

  @override
  Future<void> deleteToken() => FirebaseMessaging.instance.deleteToken();

  @override
  Stream<String> get onTokenRefresh =>
      FirebaseMessaging.instance.onTokenRefresh;

  @override
  Stream<RemoteMessage> get onMessage => FirebaseMessaging.onMessage;

  @override
  Stream<RemoteMessage> get onMessageOpenedApp =>
      FirebaseMessaging.onMessageOpenedApp;

  @override
  Future<RemoteMessage?> getInitialMessage() =>
      FirebaseMessaging.instance.getInitialMessage();
}

/// FCM on Android, used only when the build carries a Firebase config
/// (google-services.json). Without it `Firebase.initializeApp()` throws and
/// the provider reports [PushStatus.notConfigured].
class FcmPushProvider implements PushProvider {
  FcmPushProvider({PushMessagingClient? messaging})
    : _messaging = messaging ?? FirebasePushMessagingClient();

  final PushMessagingClient _messaging;
  bool _initialized = false;

  /// Last foreground messageId handled: FCM may redeliver, and the caller's
  /// reaction (a channels sync) need not run twice.
  String? _lastMessageId;

  @override
  String get platform => 'fcm';

  @override
  Future<String> obtainToken() async {
    try {
      if (!_initialized) {
        await _messaging.initializeFirebase();
        _initialized = true;
      }
      final token = await _messaging.getToken();
      if (token == null || token.isEmpty) {
        throw const PushUnavailable(PushStatus.notConfigured, 'no FCM token');
      }
      return token;
    } on PushUnavailable {
      rethrow;
    } catch (e) {
      throw PushUnavailable(PushStatus.notConfigured, e);
    }
  }

  @override
  Stream<String> get tokenRefresh => _messaging.onTokenRefresh;

  @override
  Stream<Map<String, String>> get opened =>
      _messaging.onMessageOpenedApp.map(_data);

  @override
  Future<Map<String, String>?> takeInitialOpened() async {
    final message = await _messaging.getInitialMessage();
    return message == null ? null : _data(message);
  }

  @override
  Stream<Map<String, String>> get foreground => _messaging.onMessage
      .where((m) {
        final id = m.messageId;
        if (id != null && id == _lastMessageId) return false;
        _lastMessageId = id;
        return true;
      })
      .map(_data);

  @override
  Future<void> release() async {
    if (_initialized) await _messaging.deleteToken();
  }

  static Map<String, String> _data(RemoteMessage m) => {
    for (final e in m.data.entries)
      if (e.value is String) e.key: e.value as String,
  };
}

// -- APNs (iOS) ---------------------------------------------------------------

/// Native APNs token from AppDelegate.swift over a method channel, NOT
/// Firebase (spec section 2, iOS): the server talks to APNs directly.
class ApnsPushProvider implements PushProvider {
  ApnsPushProvider({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('cz.zcloud.jay/apns') {
    _channel.setMethodCallHandler(_onCall);
  }

  final MethodChannel _channel;
  final _tokens = StreamController<String>.broadcast();
  final _opened = StreamController<Map<String, String>>.broadcast();

  @override
  String get platform => 'apns';

  /// Contract 1.1: 64..200 hex characters.
  static final _hex = RegExp(r'^[0-9a-f]{64,200}$');

  @override
  Future<String> obtainToken() async {
    try {
      final token = (await _channel.invokeMethod<String>(
        'register',
      ))?.toLowerCase();
      if (token == null || !_hex.hasMatch(token)) {
        throw const PushUnavailable(PushStatus.notConfigured, 'no APNs token');
      }
      return token;
    } on PushUnavailable {
      rethrow;
    } on PlatformException catch (e) {
      // Simulator or a build without the aps-environment entitlement.
      throw PushUnavailable(PushStatus.notConfigured, e.message);
    } on MissingPluginException catch (e) {
      throw PushUnavailable(PushStatus.notConfigured, e.message);
    }
  }

  Future<Object?> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'onToken':
        final token = call.arguments;
        if (token is String && _hex.hasMatch(token.toLowerCase())) {
          _tokens.add(token.toLowerCase());
        }
      case 'onNotificationTap':
        final data = _stringMap(call.arguments);
        if (data != null) _opened.add(data);
    }
    return null;
  }

  @override
  Stream<String> get tokenRefresh => _tokens.stream;

  @override
  Stream<Map<String, String>> get opened => _opened.stream;

  @override
  Future<Map<String, String>?> takeInitialOpened() async {
    try {
      return _stringMap(
        await _channel.invokeMethod<Object?>('takeLaunchNotification'),
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Stream<Map<String, String>> get foreground => const Stream.empty();

  /// Nothing to drop locally: Apple discourages unregistering, and once the
  /// server has deleted the token nothing is sent to it.
  @override
  Future<void> release() async {}

  static Map<String, String>? _stringMap(Object? value) {
    if (value is! Map) return null;
    return {
      for (final e in value.entries)
        if (e.key is String && e.value is String)
          e.key as String: e.value as String,
    };
  }
}
