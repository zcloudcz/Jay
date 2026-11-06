// Non-web stand-in for web_platform_web.dart: every capability is absent, so
// code shared with the web compiles on the VM (and in tests) unchanged.
import 'dart:async';

import 'local_notifier.dart';
import 'notification_content.dart';

class WebPushUnsupported implements Exception {
  const WebPushUnsupported(this.reason);
  final String reason;
  @override
  String toString() => 'WebPushUnsupported: $reason';
}

class WebPlatform {
  WebPlatform._();
  static final instance = WebPlatform._();

  bool get notificationsSupported => false;
  bool get pushSupported => false;
  NotifierPermission get permission => NotifierPermission.unsupported;
  Future<NotifierPermission> requestPermission() async =>
      NotifierPermission.unsupported;
  Future<Object?> registration() async => null;
  Stream<Map<String, String>> get taps => const Stream.empty();
  Future<void> show(LocalNotification notification) async {}
  Future<void> close(NotificationTarget target) async {}
  Future<String> subscribe(String vapidPublicKey) =>
      Future.error(const WebPushUnsupported('not a browser'));
  Future<void> unsubscribe() async {}
  bool get documentFocused => true;
}
