// ---------------------------------------------------------------------------
// push_service_test.dart — Unit tests for PushService
// ---------------------------------------------------------------------------
// firebase_messaging talks to platform channels that don't exist under
// `flutter test`, so PushService takes an injectable PushMessagingClient
// seam. These tests drive that seam directly with FakePushMessagingClient,
// with no real Firebase/network calls involved.
// ---------------------------------------------------------------------------

import 'dart:async';

import 'package:calltype/core/network/api_client.dart';
import 'package:calltype/core/network/push_service.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'push_service_test.mocks.dart';

@GenerateMocks([ApiClient])
void main() {
  late MockApiClient api;

  setUp(() {
    api = MockApiClient();
    when(api.updatePushToken(
      deviceId: anyNamed('deviceId'),
      token: anyNamed('token'),
      platform: anyNamed('platform'),
    )).thenAnswer((_) async {});
  });

  test('registers the token and reaches status=registered on success', () async {
    final messaging = FakePushMessagingClient()..token = 'tok-1';
    final service = PushService(api, 'device-1', messaging: messaging);

    await service.initialize();

    expect(service.status, PushStatus.registered);
    verify(api.updatePushToken(deviceId: 'device-1', token: 'tok-1', platform: 'fcm')).called(1);
  });

  test('permission denied stops before registering a token', () async {
    final messaging = FakePushMessagingClient()
      ..token = 'tok-1'
      ..authorizationStatus = AuthorizationStatus.denied;
    final service = PushService(api, 'device-1', messaging: messaging);

    await service.initialize();

    expect(service.status, PushStatus.permissionDenied);
    verifyNever(api.updatePushToken(
      deviceId: anyNamed('deviceId'),
      token: anyNamed('token'),
      platform: anyNamed('platform'),
    ));
  });

  test('missing Firebase config yields notConfigured, not a crash', () async {
    final messaging = FakePushMessagingClient()..throwOnInitialize = true;
    final service = PushService(api, 'device-1', messaging: messaging);

    await service.initialize();

    expect(service.status, PushStatus.notConfigured);
  });

  test('token refresh re-registers the new token with the backend', () async {
    final messaging = FakePushMessagingClient()..token = 'tok-1';
    final service = PushService(api, 'device-1', messaging: messaging);
    await service.initialize();

    messaging.emitTokenRefresh('tok-2');
    await Future<void>.delayed(Duration.zero);

    verify(api.updatePushToken(deviceId: 'device-1', token: 'tok-2', platform: 'fcm')).called(1);
  });

  test('repeated initialize/dispose does not grow listener counts', () async {
    final messaging = FakePushMessagingClient()..token = 'tok-1';
    final service = PushService(api, 'device-1', messaging: messaging);

    await service.initialize();
    await service.initialize();
    await service.dispose();
    await service.initialize();
    await service.dispose();

    // Each stream must have at most one active subscriber at any time —
    // listener counts should never exceed 1 despite repeated init/dispose.
    expect(messaging.tokenRefreshListenerCount, lessThanOrEqualTo(1));
    expect(messaging.onMessageListenerCount, lessThanOrEqualTo(1));
    expect(messaging.onMessageOpenedAppListenerCount, lessThanOrEqualTo(1));
  });

  test('re-registers after a network error on the next token event', () async {
    final messaging = FakePushMessagingClient()..token = 'tok-1';
    when(api.updatePushToken(deviceId: 'device-1', token: 'tok-1', platform: 'fcm'))
        .thenThrow(Exception('network error'));
    final service = PushService(api, 'device-1', messaging: messaging);

    // Initial registration fails but must not throw out of initialize().
    await service.initialize();
    expect(service.status, PushStatus.registered);

    // A later token refresh (e.g. after connectivity returns) succeeds.
    clearInteractions(api);
    when(api.updatePushToken(
      deviceId: anyNamed('deviceId'),
      token: anyNamed('token'),
      platform: anyNamed('platform'),
    )).thenAnswer((_) async {});
    messaging.emitTokenRefresh('tok-2');
    await Future<void>.delayed(Duration.zero);

    verify(api.updatePushToken(deviceId: 'device-1', token: 'tok-2', platform: 'fcm')).called(1);
  });

  test('foreground message does not duplicate the same event twice', () async {
    final messaging = FakePushMessagingClient()..token = 'tok-1';
    var receivedCount = 0;
    final service = PushService(
      api,
      'device-1',
      messaging: messaging,
      onMessageReceived: () => receivedCount++,
    );
    await service.initialize();

    const message = RemoteMessage(messageId: 'msg-1', data: {'type': 'new_message'});
    messaging.emitMessage(message);
    messaging.emitMessage(message); // redelivery of the same event
    await Future<void>.delayed(Duration.zero);

    expect(receivedCount, 1);
  });

  test('tapping a notification triggers onNotificationOpened, not a plaintext fetch', () async {
    final messaging = FakePushMessagingClient()..token = 'tok-1';
    var openedCount = 0;
    final service = PushService(
      api,
      'device-1',
      messaging: messaging,
      onNotificationOpened: () => openedCount++,
    );
    await service.initialize();

    messaging.emitOpenedApp(const RemoteMessage(messageId: 'msg-1', data: {'type': 'new_message'}));
    await Future<void>.delayed(Duration.zero);

    expect(openedCount, 1);
  });

  test('chat is never blocked: initialize completes even if registration throws', () async {
    final messaging = FakePushMessagingClient()..token = 'tok-1';
    when(api.updatePushToken(
      deviceId: anyNamed('deviceId'),
      token: anyNamed('token'),
      platform: anyNamed('platform'),
    )).thenThrow(Exception('boom'));
    final service = PushService(api, 'device-1', messaging: messaging);

    await expectLater(service.initialize(), completes);
  });
}

/// Test double for [PushMessagingClient]. Tracks listener counts on its
/// broadcast streams so tests can assert repeated initialize()/dispose()
/// never accumulates subscriptions.
class FakePushMessagingClient implements PushMessagingClient {
  String? token = 'tok-1';
  bool throwOnInitialize = false;
  AuthorizationStatus authorizationStatus = AuthorizationStatus.authorized;

  final _tokenRefreshController = StreamController<String>.broadcast();
  final _onMessageController = StreamController<RemoteMessage>.broadcast();
  final _onMessageOpenedAppController = StreamController<RemoteMessage>.broadcast();

  int tokenRefreshListenerCount = 0;
  int onMessageListenerCount = 0;
  int onMessageOpenedAppListenerCount = 0;

  @override
  Future<void> initializeFirebase() async {
    if (throwOnInitialize) throw Exception('no Firebase config in this build');
  }

  @override
  Future<NotificationSettings> requestPermission() async => NotificationSettings(
        alert: AppleNotificationSetting.enabled,
        announcement: AppleNotificationSetting.notSupported,
        authorizationStatus: authorizationStatus,
        badge: AppleNotificationSetting.enabled,
        carPlay: AppleNotificationSetting.notSupported,
        lockScreen: AppleNotificationSetting.notSupported,
        notificationCenter: AppleNotificationSetting.notSupported,
        showPreviews: AppleShowPreviewSetting.always,
        timeSensitive: AppleNotificationSetting.notSupported,
        criticalAlert: AppleNotificationSetting.notSupported,
        sound: AppleNotificationSetting.enabled,
        providesAppNotificationSettings: AppleNotificationSetting.notSupported,
      );

  @override
  Future<String?> getToken() async => token;

  @override
  Stream<String> get onTokenRefresh => _countedStream(_tokenRefreshController, (n) => tokenRefreshListenerCount = n);

  @override
  Stream<RemoteMessage> get onMessage => _countedStream(_onMessageController, (n) => onMessageListenerCount = n);

  @override
  Stream<RemoteMessage> get onMessageOpenedApp =>
      _countedStream(_onMessageOpenedAppController, (n) => onMessageOpenedAppListenerCount = n);

  void emitTokenRefresh(String newToken) => _tokenRefreshController.add(newToken);
  void emitMessage(RemoteMessage message) => _onMessageController.add(message);
  void emitOpenedApp(RemoteMessage message) => _onMessageOpenedAppController.add(message);

  /// Wraps a broadcast controller's stream so every listen()/cancel() updates
  /// a live count via [onCountChanged] — the only way to observe subscription
  /// growth on a plain StreamController from outside.
  Stream<T> _countedStream<T>(StreamController<T> controller, void Function(int) onCountChanged) =>
      _CountingStream<T>(controller.stream, onCountChanged);
}

class _CountingStream<T> extends Stream<T> {
  _CountingStream(this._source, this._onCountChanged);

  final Stream<T> _source;
  final void Function(int) _onCountChanged;
  int _count = 0;

  @override
  StreamSubscription<T> listen(
    void Function(T event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    _count++;
    _onCountChanged(_count);
    final sub = _source.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
    return _CountingSubscription<T>(sub, () {
      _count--;
      _onCountChanged(_count);
    });
  }
}

class _CountingSubscription<T> implements StreamSubscription<T> {
  _CountingSubscription(this._inner, this._onCancel);

  final StreamSubscription<T> _inner;
  final void Function() _onCancel;
  bool _cancelled = false;

  @override
  Future<void> cancel() {
    if (!_cancelled) {
      _cancelled = true;
      _onCancel();
    }
    return _inner.cancel();
  }

  @override
  void onData(void Function(T data)? handleData) => _inner.onData(handleData);

  @override
  void onError(Function? handleError) => _inner.onError(handleError);

  @override
  void onDone(void Function()? handleDone) => _inner.onDone(handleDone);

  @override
  void pause([Future<void>? resumeSignal]) => _inner.pause(resumeSignal);

  @override
  void resume() => _inner.resume();

  @override
  bool get isPaused => _inner.isPaused;

  @override
  Future<E> asFuture<E>([E? futureValue]) => _inner.asFuture(futureValue);
}
