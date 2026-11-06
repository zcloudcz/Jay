import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'local_notifier.dart';
import 'notification_content.dart';

/// [LocalNotifier] over flutter_local_notifications for Android, iOS, macOS,
/// Windows and Linux. Never used on web (see web_notifier.dart) and never in
/// tests (platform channels do not exist there).
class PluginLocalNotifier implements LocalNotifier {
  PluginLocalNotifier({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  final _taps = StreamController<Map<String, String>>.broadcast();
  NotificationChannelNames? _names;

  /// Windows identifies the app's toast activator by this GUID; it must stay
  /// the same across releases or old toasts stop activating the app.
  static const _windowsGuid = 'c4f0a6e2-5b7d-4c1e-9a3f-2d8e6b1f7a90';

  @override
  Future<void> initialize(NotificationChannelNames names) async {
    _names = names;
    // Darwin: never prompt during initialize. The prompt comes from
    // requestPermission() at a moment the service picks (spec section 2).
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(
      settings: InitializationSettings(
        // A monochrome drawable: Android tints the status-bar icon and shows
        // a launcher mipmap as a white square.
        android: const AndroidInitializationSettings('@drawable/ic_stat_jay'),
        iOS: darwin,
        macOS: darwin,
        linux: LinuxInitializationSettings(defaultActionName: names.openAction),
        windows: const WindowsInitializationSettings(
          appName: 'Jay',
          appUserModelId: 'cz.zcloud.jay',
          guid: _windowsGuid,
        ),
      ),
      onDidReceiveNotificationResponse: (response) {
        final data = _decode(response.payload);
        if (data != null) _taps.add(data);
      },
    );
    final android = _android;
    if (android != null) {
      // Ids fixed by contract 1.3: the server's FCM pushes name the same
      // channels, so both kinds of notifications share the user's settings.
      await android.createNotificationChannel(
        AndroidNotificationChannel(
          NotificationKind.message.androidChannelId,
          names.messages,
          importance: Importance.high,
        ),
      );
      await android.createNotificationChannel(
        AndroidNotificationChannel(
          NotificationKind.incomingCall.androidChannelId,
          names.calls,
          importance: Importance.max,
        ),
      );
      await android.createNotificationChannel(
        AndroidNotificationChannel(
          NotificationKind.channelPost.androidChannelId,
          names.channels,
        ),
      );
    }
  }

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  IOSFlutterLocalNotificationsPlugin? get _ios => _plugin
      .resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin
      >();

  MacOSFlutterLocalNotificationsPlugin? get _macos => _plugin
      .resolvePlatformSpecificImplementation<
        MacOSFlutterLocalNotificationsPlugin
      >();

  @override
  Future<NotifierPermission> permission() async {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        final enabled = await _android?.areNotificationsEnabled();
        return enabled == true
            ? NotifierPermission.granted
            : NotifierPermission.denied;
      case TargetPlatform.iOS:
        final options = await _ios?.checkPermissions();
        return options?.isEnabled == true
            ? NotifierPermission.granted
            : NotifierPermission.denied;
      case TargetPlatform.macOS:
        final options = await _macos?.checkPermissions();
        return options?.isEnabled == true
            ? NotifierPermission.granted
            : NotifierPermission.denied;
      default:
        // Windows / Linux have no per-app permission prompt.
        return NotifierPermission.granted;
    }
  }

  @override
  Future<NotifierPermission> requestPermission() async {
    bool? granted;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        granted = await _android?.requestNotificationsPermission();
      case TargetPlatform.iOS:
        granted = await _ios?.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        );
      case TargetPlatform.macOS:
        granted = await _macos?.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        );
      default:
        granted = true;
    }
    return granted == true
        ? NotifierPermission.granted
        : NotifierPermission.denied;
  }

  @override
  bool get permissionNeedsUserGesture => false;

  @override
  Future<void> show(LocalNotification notification) async {
    final target = notification.target;
    final kind = notification.effectiveKind;
    final names = _names;
    final channelName = switch (kind) {
      NotificationKind.incomingCall => names?.calls,
      NotificationKind.channelPost => names?.channels,
      _ => names?.messages,
    };
    final darwin = DarwinNotificationDetails(
      // Groups the notifications of one chat (APNs `thread-id` does the same
      // for server pushes).
      threadIdentifier: target?.conversationId,
    );
    await _plugin.show(
      id: notification.id,
      title: notification.title,
      body: notification.body,
      payload: jsonEncode(notification.data),
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          kind.androidChannelId,
          channelName ?? kind.androidChannelId,
          importance: kind == NotificationKind.incomingCall
              ? Importance.max
              : Importance.high,
          priority: Priority.high,
          category: kind == NotificationKind.incomingCall
              ? AndroidNotificationCategory.call
              : AndroidNotificationCategory.message,
          // Same tag as the server's FCM push for this conversation: a
          // later notification replaces the earlier one (spec N4).
          tag: target?.conversationId,
          styleInformation: BigTextStyleInformation(notification.body),
        ),
        iOS: darwin,
        macOS: darwin,
        linux: const LinuxNotificationDetails(),
        windows: const WindowsNotificationDetails(),
      ),
    );
  }

  @override
  Future<void> cancel(NotificationTarget target) => _plugin.cancel(
    id: notificationIdFor(target.kind, target.conversationId),
    tag: target.conversationId,
  );

  @override
  Stream<Map<String, String>> get taps => _taps.stream;

  @override
  Future<Map<String, String>?> takeLaunchTap() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details == null || !details.didNotificationLaunchApp) return null;
    return _decode(details.notificationResponse?.payload);
  }

  static Map<String, String>? _decode(String? payload) {
    if (payload == null) return null;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) return null;
      return {
        for (final e in decoded.entries)
          if (e.key is String && e.value is String)
            e.key as String: e.value as String,
      };
    } on FormatException {
      return null;
    }
  }
}
