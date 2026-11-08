// ---------------------------------------------------------------------------
// push_service_test.dart: PushService and the per-platform push providers.
// ---------------------------------------------------------------------------
// firebase_messaging and the APNs method channel talk to platform code that
// does not exist under `flutter test`, so FCM goes through the injectable
// PushMessagingClient seam and APNs through a mocked MethodChannel. No real
// Firebase / network call happens here.
// ---------------------------------------------------------------------------

import 'dart:async';

import 'package:calltype_core/network/api_client.dart';
import 'package:calltype/core/network/push_service.dart';
import 'package:calltype/features/notifications/web_push_provider.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'push_service_test.mocks.dart';

@GenerateMocks([ApiClient])
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MockApiClient api;

  void stubPut() => when(
    api.updatePushToken(
      deviceId: anyNamed('deviceId'),
      token: anyNamed('token'),
      platform: anyNamed('platform'),
      locale: anyNamed('locale'),
    ),
  ).thenAnswer((_) async {});

  setUp(() {
    api = MockApiClient();
    stubPut();
    when(api.deletePushToken(any)).thenAnswer((_) async {});
  });

  PushService fcmService(
    FakePushMessagingClient messaging, {
    void Function(Map<String, String>)? onForegroundPush,
    void Function(Map<String, String>)? onOpened,
  }) => PushService(
    api,
    'device-1',
    provider: FcmPushProvider(messaging: messaging),
    locale: () => 'cs',
    onForegroundPush: onForegroundPush,
    onOpened: onOpened,
  );

  group('FCM (Android)', () {
    test('registers platform fcm with the app locale', () async {
      final service = fcmService(FakePushMessagingClient()..token = 'tok-1');

      expect(await service.register(), PushStatus.registered);
      verify(
        api.updatePushToken(
          deviceId: 'device-1',
          token: 'tok-1',
          platform: 'fcm',
          locale: 'cs',
        ),
      ).called(1);
    });

    test('missing Firebase config yields notConfigured, not a crash', () async {
      final service = fcmService(
        FakePushMessagingClient()..throwOnInitialize = true,
      );

      expect(await service.register(), PushStatus.notConfigured);
      verifyNever(
        api.updatePushToken(
          deviceId: anyNamed('deviceId'),
          token: anyNamed('token'),
          platform: anyNamed('platform'),
          locale: anyNamed('locale'),
        ),
      );
    });

    test('no token yields notConfigured', () async {
      final service = fcmService(FakePushMessagingClient()..token = null);
      expect(await service.register(), PushStatus.notConfigured);
    });

    test('token refresh re-registers the new token', () async {
      final messaging = FakePushMessagingClient()..token = 'tok-1';
      final service = fcmService(messaging);
      await service.register();

      messaging.emitTokenRefresh('tok-2');
      await Future<void>.delayed(Duration.zero);

      verify(
        api.updatePushToken(
          deviceId: 'device-1',
          token: 'tok-2',
          platform: 'fcm',
          locale: 'cs',
        ),
      ).called(1);
    });

    test('repeated register/dispose does not grow listener counts', () async {
      final messaging = FakePushMessagingClient()..token = 'tok-1';
      final service = fcmService(messaging);

      await service.register();
      await service.register();
      await service.dispose();
      await service.register();
      await service.dispose();

      expect(messaging.tokenRefreshListenerCount, lessThanOrEqualTo(1));
      expect(messaging.onMessageListenerCount, lessThanOrEqualTo(1));
      expect(messaging.onMessageOpenedAppListenerCount, lessThanOrEqualTo(1));
    });

    test('a failed PUT never throws out of register and is retried', () async {
      final messaging = FakePushMessagingClient()..token = 'tok-1';
      when(
        api.updatePushToken(
          deviceId: anyNamed('deviceId'),
          token: anyNamed('token'),
          platform: anyNamed('platform'),
          locale: anyNamed('locale'),
        ),
      ).thenThrow(Exception('network error'));
      final service = fcmService(messaging);

      await expectLater(service.register(), completes);

      // The next reconnect calls register() again.
      clearInteractions(api);
      stubPut();
      await service.register();
      verify(
        api.updatePushToken(
          deviceId: 'device-1',
          token: 'tok-1',
          platform: 'fcm',
          locale: 'cs',
        ),
      ).called(1);
    });

    test('a redelivered foreground push is relayed once', () async {
      final messaging = FakePushMessagingClient();
      final received = <Map<String, String>>[];
      final service = fcmService(messaging, onForegroundPush: received.add);
      await service.register();

      const message = RemoteMessage(
        messageId: 'msg-1',
        data: {'type': 'channel_post', 'conversationId': 'c1', 'v': '1'},
      );
      messaging.emitMessage(message);
      messaging.emitMessage(message);
      await Future<void>.delayed(Duration.zero);

      expect(received, [
        {'type': 'channel_post', 'conversationId': 'c1', 'v': '1'},
      ]);
    });

    test('tapped push and the launching push reach onOpened', () async {
      final messaging = FakePushMessagingClient()
        ..initialMessage = const RemoteMessage(
          data: {'type': 'message', 'conversationId': 'peer-1', 'v': '1'},
        );
      final opened = <Map<String, String>>[];
      final service = fcmService(messaging, onOpened: opened.add);
      await service.register();
      // A second register (reconnect) must not replay the launching tap.
      await service.register();

      messaging.emitOpenedApp(
        const RemoteMessage(
          messageId: 'm-2',
          data: {'type': 'group_message', 'conversationId': 'g-1', 'v': '1'},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(opened.map((d) => d['conversationId']), ['peer-1', 'g-1']);
    });

    test('unregister deletes the server token and the FCM token', () async {
      final messaging = FakePushMessagingClient();
      final service = fcmService(messaging);
      await service.register();

      await service.unregister();

      verify(api.deletePushToken('device-1')).called(1);
      expect(messaging.deleted, isTrue);
      expect(service.status, PushStatus.idle);
      expect(messaging.tokenRefreshListenerCount, 0);
    });

    test('unregister offline still drops the local token', () async {
      final messaging = FakePushMessagingClient();
      when(api.deletePushToken(any)).thenThrow(Exception('offline'));
      final service = fcmService(messaging);
      await service.register();

      await expectLater(service.unregister(), completes);
      expect(messaging.deleted, isTrue);
    });
  });

  group('APNs (iOS, native token)', () {
    const channel = MethodChannel('cz.zcloud.jay/apns');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const hexToken =
        'ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789';

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('registers the lower-case hex token as platform apns', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'register') return hexToken;
        return null;
      });
      final service = PushService(
        api,
        'device-1',
        provider: ApnsPushProvider(),
        locale: () => 'en-US',
      );

      expect(await service.register(), PushStatus.registered);
      verify(
        api.updatePushToken(
          deviceId: 'device-1',
          token: hexToken.toLowerCase(),
          platform: 'apns',
          locale: 'en-US',
        ),
      ).called(1);
    });

    test('a missing entitlement (simulator) is notConfigured', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(
          code: 'apns_unavailable',
          message: 'no valid aps-environment entitlement',
        );
      });
      final service = PushService(
        api,
        'device-1',
        provider: ApnsPushProvider(),
      );

      expect(await service.register(), PushStatus.notConfigured);
    });

    test('a malformed token is refused', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => 'xyz');
      final service = PushService(
        api,
        'device-1',
        provider: ApnsPushProvider(),
      );
      expect(await service.register(), PushStatus.notConfigured);
    });

    test('launch tap and live taps from AppDelegate reach onOpened', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'register') return hexToken;
        if (call.method == 'takeLaunchNotification') {
          return {'type': 'incoming_call', 'conversationId': 'p-1', 'v': '1'};
        }
        return null;
      });
      final opened = <Map<String, String>>[];
      final service = PushService(
        api,
        'device-1',
        provider: ApnsPushProvider(),
        onOpened: opened.add,
      );
      await service.register();

      // AppDelegate -> Dart: a tap while the app runs.
      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('onNotificationTap', {
            'type': 'message',
            'conversationId': 'p-2',
            'v': '1',
          }),
        ),
        (_) {},
      );
      await Future<void>.delayed(Duration.zero);

      expect(opened.map((d) => d['conversationId']), ['p-1', 'p-2']);
    });
  });

  group('Web Push', () {
    test('outside a browser it reports notConfigured', () async {
      final service = PushService(
        api,
        'device-1',
        provider: WebPushProvider(apiClient: api),
      );
      expect(await service.register(), PushStatus.notConfigured);
      verifyNever(api.getWebPushPublicKey());
    });
  });
}

/// Test double for [PushMessagingClient]. Tracks listener counts on its
/// broadcast streams so tests can assert repeated register()/dispose()
/// never accumulates subscriptions.
class FakePushMessagingClient implements PushMessagingClient {
  String? token = 'tok-1';
  bool throwOnInitialize = false;
  bool deleted = false;
  RemoteMessage? initialMessage;

  final _tokenRefreshController = StreamController<String>.broadcast();
  final _onMessageController = StreamController<RemoteMessage>.broadcast();
  final _onMessageOpenedAppController =
      StreamController<RemoteMessage>.broadcast();

  int tokenRefreshListenerCount = 0;
  int onMessageListenerCount = 0;
  int onMessageOpenedAppListenerCount = 0;

  @override
  Future<void> initializeFirebase() async {
    if (throwOnInitialize) throw Exception('no Firebase config in this build');
  }

  @override
  Future<String?> getToken() async => token;

  @override
  Future<void> deleteToken() async => deleted = true;

  @override
  Future<RemoteMessage?> getInitialMessage() async {
    final message = initialMessage;
    initialMessage = null;
    return message;
  }

  @override
  Stream<String> get onTokenRefresh => _CountingStream(
    _tokenRefreshController.stream,
    (delta) => tokenRefreshListenerCount += delta,
  );

  @override
  Stream<RemoteMessage> get onMessage => _CountingStream(
    _onMessageController.stream,
    (delta) => onMessageListenerCount += delta,
  );

  @override
  Stream<RemoteMessage> get onMessageOpenedApp => _CountingStream(
    _onMessageOpenedAppController.stream,
    (delta) => onMessageOpenedAppListenerCount += delta,
  );

  void emitTokenRefresh(String newToken) =>
      _tokenRefreshController.add(newToken);
  void emitMessage(RemoteMessage message) => _onMessageController.add(message);
  void emitOpenedApp(RemoteMessage message) =>
      _onMessageOpenedAppController.add(message);
}

/// Reports +1 / -1 per subscription to the fake's counter: the only way to
/// observe listener growth on a plain broadcast StreamController.
class _CountingStream<T> extends Stream<T> {
  _CountingStream(this._source, this._change);

  final Stream<T> _source;
  final void Function(int delta) _change;

  @override
  StreamSubscription<T> listen(
    void Function(T event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    _change(1);
    final sub = _source.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
    return _CountingSubscription<T>(sub, () => _change(-1));
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
