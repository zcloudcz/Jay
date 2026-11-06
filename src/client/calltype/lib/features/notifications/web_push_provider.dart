import 'dart:async';

import '../../core/network/api_client.dart';
import '../../core/network/push_service.dart';
import 'web_platform.dart';

/// Web Push (RFC 8030 + VAPID): the token is the browser's
/// `PushSubscription.toJSON()` as a JSON string (contract 1.1 `webpush`),
/// made with the server's key from `GET /push/webpush-key`. The worker
/// (web/push-sw.js) shows the pushes and routes clicks.
class WebPushProvider implements PushProvider {
  WebPushProvider({required ApiClient apiClient, WebPlatform? platform})
    : _api = apiClient,
      _web = platform ?? WebPlatform.instance;

  final ApiClient _api;
  final WebPlatform _web;

  @override
  String get platform => 'webpush';

  @override
  Future<String> obtainToken() async {
    if (!_web.pushSupported) {
      throw const PushUnavailable(PushStatus.notConfigured, 'no Push API');
    }
    final String? key;
    try {
      key = await _api.getWebPushPublicKey();
    } catch (e) {
      // Network error: reported as not configured for now; the next
      // reconnect registers again.
      throw PushUnavailable(PushStatus.notConfigured, e);
    }
    if (key == null) {
      throw const PushUnavailable(
        PushStatus.notConfigured,
        'Web Push is not configured on the server',
      );
    }
    try {
      return await _web.subscribe(key);
    } catch (e) {
      throw PushUnavailable(PushStatus.notConfigured, e);
    }
  }

  /// Browsers rotate subscriptions only through the worker's
  /// `pushsubscriptionchange`, which cannot reach the API; the app
  /// re-subscribes on every start and reconnect instead.
  @override
  Stream<String> get tokenRefresh => const Stream.empty();

  /// Empty on purpose: push-sw.js reports clicks on server pushes and on
  /// local notifications through the same message, which WebLocalNotifier
  /// already delivers; listening here too would open the chat twice.
  @override
  Stream<Map<String, String>> get opened => const Stream.empty();

  @override
  Future<Map<String, String>?> takeInitialOpened() async => null;

  @override
  Stream<Map<String, String>> get foreground => const Stream.empty();

  @override
  Future<void> release() => _web.unsubscribe();
}
