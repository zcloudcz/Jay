import 'dart:async';

import 'notification_content.dart';

/// OS notification permission as the app sees it.
enum NotifierPermission {
  granted,
  denied,

  /// Never asked (web `default`, iOS `notDetermined`).
  notDetermined,

  /// The platform / browser cannot show notifications at all.
  unsupported,
}

/// One notification to show.
class LocalNotification {
  const LocalNotification({
    required this.target,
    required this.title,
    required this.body,
    this.kind = NotificationKind.message,
  });

  /// What a tap opens. Null only for the settings test notification, whose
  /// tap simply opens the app (chat list).
  final NotificationTarget? target;
  final String title;
  final String body;
  final NotificationKind kind;

  NotificationKind get effectiveKind => target?.kind ?? kind;

  /// Stable per conversation: a newer one replaces the older (spec N4).
  int get id => target == null
      ? 0
      : notificationIdFor(target!.kind, target!.conversationId);

  /// Tap data, same keys as a server push.
  Map<String, String> get data => target?.toData() ?? const {};
}

/// Localized names the OS shows in its notification settings (Android
/// channels) or as an action label (Linux). Passed in because the notifier
/// has no BuildContext.
class NotificationChannelNames {
  const NotificationChannelNames({
    required this.messages,
    required this.calls,
    required this.channels,
    required this.openAction,
  });

  final String messages;
  final String calls;
  final String channels;
  final String openAction;
}

/// Seam over the platform notification APIs (flutter_local_notifications on
/// mobile/desktop, the browser Notification API on web). Tests use a fake:
/// none of the real implementations works under `flutter test`.
abstract class LocalNotifier {
  /// Prepares the platform (Android channels, tap callbacks). Throws when the
  /// platform part is missing; callers treat that as "unsupported".
  Future<void> initialize(NotificationChannelNames names);

  Future<NotifierPermission> permission();

  /// Shows the OS prompt. On web this must run inside a user gesture
  /// ([permissionNeedsUserGesture]).
  Future<NotifierPermission> requestPermission();

  /// Web: browsers ignore (and may penalize) a prompt without a click.
  bool get permissionNeedsUserGesture;

  Future<void> show(LocalNotification notification);

  Future<void> cancel(NotificationTarget target);

  /// Data (`{type, conversationId, v}`) of a notification the user tapped
  /// while the app was running.
  Stream<Map<String, String>> get taps;

  /// Data of the notification that launched the app, once; null otherwise.
  Future<Map<String, String>?> takeLaunchTap();
}

/// Platforms without any notification support: everything is a no-op, so
/// the rest of the app never has to branch on the platform.
class NoopLocalNotifier implements LocalNotifier {
  @override
  Future<void> initialize(NotificationChannelNames names) async {}

  @override
  Future<NotifierPermission> permission() async =>
      NotifierPermission.unsupported;

  @override
  Future<NotifierPermission> requestPermission() async =>
      NotifierPermission.unsupported;

  @override
  bool get permissionNeedsUserGesture => false;

  @override
  Future<void> show(LocalNotification notification) async {}

  @override
  Future<void> cancel(NotificationTarget target) async {}

  @override
  Stream<Map<String, String>> get taps => const Stream.empty();

  @override
  Future<Map<String, String>?> takeLaunchTap() async => null;
}
