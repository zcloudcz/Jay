import 'local_notifier.dart';
import 'notification_content.dart';
import 'web_platform.dart';

/// [LocalNotifier] for the browser (spec section 2: web uses the
/// Notification API via package:web, not the plugin's own worker, so taps of
/// local and server notifications share one worker, web/push-sw.js).
class WebLocalNotifier implements LocalNotifier {
  WebLocalNotifier([WebPlatform? platform])
    : _web = platform ?? WebPlatform.instance;

  final WebPlatform _web;

  @override
  Future<void> initialize(NotificationChannelNames names) async {
    // Registering the worker early lets a click on a notification shown
    // while the app was closed reach this tab once it is open again.
    if (_web.notificationsSupported) await _web.registration();
  }

  @override
  Future<NotifierPermission> permission() async => _web.permission;

  @override
  Future<NotifierPermission> requestPermission() => _web.requestPermission();

  @override
  bool get permissionNeedsUserGesture => true;

  @override
  Future<void> show(LocalNotification notification) => _web.show(notification);

  @override
  Future<void> cancel(NotificationTarget target) => _web.close(target);

  @override
  Stream<Map<String, String>> get taps => _web.taps;

  /// A click on a notification while no tab was open opens the app at the
  /// target route directly (push-sw.js), so there is nothing to replay.
  @override
  Future<Map<String, String>?> takeLaunchTap() async => null;
}
