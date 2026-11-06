// Web side of notifications: the browser Notification API, the push service
// worker (web/push-sw.js) and the Web Push subscription. Only compiled for
// the web (see web_platform.dart); the VM and tests get the stub.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'local_notifier.dart';
import 'notification_content.dart';

/// Thrown when the browser lacks a piece the caller needs.
class WebPushUnsupported implements Exception {
  const WebPushUnsupported(this.reason);
  final String reason;
  @override
  String toString() => 'WebPushUnsupported: $reason';
}

class WebPlatform {
  WebPlatform._();
  static final instance = WebPlatform._();

  final _taps = StreamController<Map<String, String>>.broadcast();
  Future<web.ServiceWorkerRegistration?>? _registration;
  bool _listening = false;

  /// The push worker lives at `/push-sw.js` but is registered with the
  /// NARROW scope `/push/`. WHY: Flutter's own `flutter_service_worker.js`
  /// is registered for `/` by the bootstrap, and a scope holds exactly one
  /// worker, so ours would replace it on every start and Flutter's would
  /// replace ours on the next. A push worker controls no page anyway: push,
  /// notification clicks and `clients.matchAll({includeUncontrolled})` work
  /// from any scope of the origin, and `/admin/` stays untouched.
  static const workerScript = 'push-sw.js';
  static const workerScope = 'push/';

  bool get notificationsSupported => web.window.has('Notification');

  bool get _serviceWorkerSupported =>
      (web.window.navigator as JSObject).has('serviceWorker');

  bool get pushSupported =>
      _serviceWorkerSupported && web.window.has('PushManager');

  NotifierPermission get permission {
    if (!notificationsSupported) return NotifierPermission.unsupported;
    return switch (web.Notification.permission) {
      'granted' => NotifierPermission.granted,
      'denied' => NotifierPermission.denied,
      _ => NotifierPermission.notDetermined,
    };
  }

  Future<NotifierPermission> requestPermission() async {
    if (!notificationsSupported) return NotifierPermission.unsupported;
    await web.Notification.requestPermission().toDart;
    return permission;
  }

  /// Registers (once) the push worker and starts listening for its
  /// notification-click messages. Null when the browser has no service
  /// workers (old Safari, private modes) or registration failed.
  Future<web.ServiceWorkerRegistration?> registration() {
    _listen();
    return _registration ??= _register();
  }

  Future<web.ServiceWorkerRegistration?> _register() async {
    if (!_serviceWorkerSupported) return null;
    try {
      return await web.window.navigator.serviceWorker
          .register(
            workerScript.toJS,
            web.RegistrationOptions(scope: workerScope),
          )
          .toDart;
    } catch (_) {
      return null;
    }
  }

  void _listen() {
    if (_listening || !_serviceWorkerSupported) return;
    _listening = true;
    // Messages from push-sw.js: {jay: 'notification-click', data: {...}}.
    // A Client.postMessage reaches this container whether or not the worker
    // controls the page, which the narrow scope relies on.
    web.window.navigator.serviceWorker.addEventListener(
      'message',
      ((web.MessageEvent event) {
        final message = event.data;
        if (message == null || !message.isA<JSObject>()) return;
        final object = message as JSObject;
        if (object['jay']?.dartify() != 'notification-click') return;
        final data = _stringMap(object['data']);
        if (data != null) _taps.add(data);
      }).toJS,
    );
  }

  Stream<Map<String, String>> get taps {
    _listen();
    return _taps.stream;
  }

  /// Shows [notification] through the worker when possible (the only way on
  /// Android Chrome, where `new Notification()` throws), else directly.
  Future<void> show(LocalNotification notification) async {
    if (permission != NotifierPermission.granted) return;
    final data = notification.data;
    final options = web.NotificationOptions(
      body: notification.body,
      // Same tag as the server's Web Push for this conversation: the newer
      // notification replaces the older one (spec N4).
      tag: notification.target?.conversationId ?? 'jay',
      icon: 'icons/Icon-192.png',
      data: data.jsify(),
    );
    final registration = await this.registration();
    if (registration != null) {
      await registration.showNotification(notification.title, options).toDart;
      return;
    }
    final shown = web.Notification(notification.title, options);
    shown.onclick = ((web.Event _) {
      web.window.focus();
      shown.close();
      _taps.add(data);
    }).toJS;
  }

  Future<void> close(NotificationTarget target) async {
    final registration = await this.registration();
    if (registration == null) return;
    final open = await registration
        .getNotifications(
          web.GetNotificationOptions(tag: target.conversationId),
        )
        .toDart;
    for (final n in open.toDart) {
      n.close();
    }
  }

  /// Subscribes to Web Push with the server's VAPID key and returns
  /// `PushSubscription.toJSON()` serialized, the `webpush` token of contract
  /// 1.1. An old subscription made with another key is replaced (the server
  /// could not sign pushes for it).
  Future<String> subscribe(String vapidPublicKey) async {
    if (!pushSupported) throw const WebPushUnsupported('no PushManager');
    final registration = await this.registration();
    if (registration == null) {
      throw const WebPushUnsupported('service worker not registered');
    }
    // A fresh registration may still be installing; subscribe() needs an
    // active worker.
    await _activated(registration);
    final key = _base64UrlDecode(vapidPublicKey);
    final manager = registration.pushManager;
    var subscription = await manager.getSubscription().toDart;
    if (subscription != null) {
      final current = subscription.options.applicationServerKey;
      if (current == null || !_sameBytes(current.toDart.asUint8List(), key)) {
        await subscription.unsubscribe().toDart;
        subscription = null;
      }
    }
    subscription ??= await manager
        .subscribe(
          web.PushSubscriptionOptionsInit(
            userVisibleOnly: true,
            applicationServerKey: key.toJS,
          ),
        )
        .toDart;
    final json = subscription.toJSON().dartify();
    return jsonEncode(json);
  }

  Future<void> unsubscribe() async {
    if (!pushSupported) return;
    final registration = await this.registration();
    if (registration == null) return;
    final subscription = await registration.pushManager
        .getSubscription()
        .toDart;
    if (subscription != null) await subscription.unsubscribe().toDart;
  }

  /// True when the tab is visible AND has focus; Flutter's lifecycle alone
  /// reports "resumed" for a visible tab in an unfocused window.
  bool get documentFocused =>
      web.document.visibilityState == 'visible' && web.document.hasFocus();

  static Future<void> _activated(web.ServiceWorkerRegistration r) async {
    if (r.active != null) return;
    final worker = r.installing ?? r.waiting;
    if (worker == null) return;
    final done = Completer<void>();
    worker.addEventListener(
      'statechange',
      ((web.Event _) {
        if (worker.state == 'activated' && !done.isCompleted) done.complete();
      }).toJS,
    );
    await done.future.timeout(const Duration(seconds: 10), onTimeout: () {});
  }

  static Map<String, String>? _stringMap(JSAny? value) {
    final dart = value.dartify();
    if (dart is! Map) return null;
    return {
      for (final e in dart.entries)
        if (e.key is String && e.value is String)
          e.key as String: e.value as String,
    };
  }

  static Uint8List _base64UrlDecode(String value) {
    final padded = value.padRight((value.length + 3) ~/ 4 * 4, '=');
    return base64Url.decode(padded);
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
