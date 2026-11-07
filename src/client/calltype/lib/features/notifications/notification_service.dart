import 'dart:async';

import 'package:calltype_core/network/channel_dtos.dart' show ChannelPostDto;
import 'package:calltype_core/network/group_dtos.dart' show MuteMode;
import 'package:flutter/foundation.dart';

import '../../core/network/api_client.dart';
import '../../core/network/push_service.dart';
import '../../core/storage/database.dart';
import '../../l10n/l10n.dart';
import '../chat/attachment.dart';
import 'local_notifier.dart';
import 'notification_content.dart';

/// Small key-value store for the notification settings (SecureStorage in the
/// app, a map in tests).
abstract class NotificationPrefsStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

/// Names and facts the notification texts need, read from the local
/// database / controllers. A seam so the service is testable without drift.
abstract class NotificationDirectory {
  /// "Me": messages from this identity (another own device) never notify.
  String? get selfIdentityId;

  /// Whether [conversationId] is a group and its display name (group name,
  /// or the contact's name / handle for a 1:1).
  Future<({bool group, String? title})> conversation(String conversationId);

  /// A contact's display name (or handle) and bot flag.
  Future<({String? name, bool isBot})> contact(String identityId);

  /// The identity (primary device) a device belongs to: the 1:1 id a call
  /// notification opens.
  Future<String> identityOfDevice(String deviceId);

  String? channelName(String channelId);
}

/// What the Settings screen shows (spec section 2: permission denied / not
/// configured / active, plus the states around them).
enum NotificationState {
  /// The user turned notifications off.
  off,

  /// No notification support at all (old browser).
  unsupported,

  /// The OS / browser permission was refused.
  permissionDenied,

  /// Permission never asked yet; needs the "Allow" button (web always,
  /// mobile only if the automatic prompt was skipped).
  permissionRequired,

  /// Local notifications work; this platform has no server push (desktop).
  localOnly,

  /// Local notifications work; the server push is not available in this
  /// build / browser / server (no Firebase config, no APNs entitlement, no
  /// VAPID key).
  pushNotConfigured,

  /// Local notifications work; push registration not done yet (offline).
  pushPending,

  /// Local notifications and server push work.
  active,
}

/// Local notifications for messages, calls and channel posts, the server
/// push registration and the notification settings (spec 2026-11-06, N1 and
/// section 2). Lives app-wide (main.dart) like the inbox: notifications are
/// needed whichever screen is open.
class NotificationService extends ChangeNotifier {
  NotificationService({
    required LocalNotifier notifier,
    required NotificationPrefsStore prefs,
    required AppLocalizations Function() strings,
    required NotificationDirectory directory,
    required String? Function() currentPath,
    required bool Function() appFocused,
    required void Function(String route) openRoute,
    required MuteMode Function(String conversationId) muteOf,
    ApiClient? apiClient,
    PushProvider? pushProvider,
    String? Function()? deviceId,
    String? Function()? locale,
    void Function(Map<String, String> data)? onForegroundPush,
  }) : _notifier = notifier,
       _prefs = prefs,
       _strings = strings,
       _directory = directory,
       _currentPath = currentPath,
       _appFocused = appFocused,
       _openRoute = openRoute,
       _muteOf = muteOf,
       _api = apiClient,
       _pushProvider = pushProvider,
       _deviceId = deviceId ?? (() => null),
       _locale = locale ?? (() => null),
       _onForegroundPush = onForegroundPush;

  final LocalNotifier _notifier;
  final NotificationPrefsStore _prefs;
  final AppLocalizations Function() _strings;
  final NotificationDirectory _directory;
  final String? Function() _currentPath;
  final bool Function() _appFocused;
  final void Function(String route) _openRoute;
  final MuteMode Function(String conversationId) _muteOf;
  final ApiClient? _api;
  final PushProvider? _pushProvider;
  final String? Function() _deviceId;
  final String? Function() _locale;
  final void Function(Map<String, String> data)? _onForegroundPush;

  static const _keyEnabled = 'ct_notifications_enabled';
  static const _keyPreviews = 'ct_notifications_previews';
  static const _keyAsked = 'ct_notifications_permission_asked';
  static const _keyBannerDismissed = 'ct_notifications_banner_dismissed';

  // Spec defaults: notifications on, previews on.
  bool _enabled = true;
  bool _previews = true;
  bool _asked = false;
  bool _bannerDismissed = false;
  bool _supported = true;
  NotifierPermission _permission = NotifierPermission.notDetermined;
  PushService? _push;
  final _subscriptions = <StreamSubscription<Object?>>[];
  NotificationTarget? _ringing;
  bool _disposed = false;

  bool get enabled => _enabled;
  bool get previews => _previews;
  NotifierPermission get permission => _permission;
  PushStatus get pushStatus => _push?.status ?? PushStatus.idle;
  bool get hasServerPush => _pushProvider != null;

  /// Web only (permission needs a click): the one-time "turn on" banner.
  bool get showPermissionBanner =>
      _supported &&
      _enabled &&
      !_bannerDismissed &&
      _notifier.permissionNeedsUserGesture &&
      _permission == NotifierPermission.notDetermined;

  NotificationState get state {
    if (!_enabled) return NotificationState.off;
    if (!_supported || _permission == NotifierPermission.unsupported) {
      return NotificationState.unsupported;
    }
    if (_permission == NotifierPermission.notDetermined) {
      return NotificationState.permissionRequired;
    }
    if (_permission == NotifierPermission.denied) {
      // Android/iOS report "not enabled" before the first prompt too; only
      // after we asked is it really a refusal.
      return _asked || _notifier.permissionNeedsUserGesture
          ? NotificationState.permissionDenied
          : NotificationState.permissionRequired;
    }
    if (_pushProvider == null) return NotificationState.localOnly;
    return switch (pushStatus) {
      PushStatus.registered => NotificationState.active,
      PushStatus.idle => NotificationState.pushPending,
      PushStatus.permissionDenied => NotificationState.permissionDenied,
      PushStatus.unsupported => NotificationState.localOnly,
      PushStatus.notConfigured => NotificationState.pushNotConfigured,
    };
  }

  /// Loads the settings, prepares the platform and starts listening for
  /// taps. Never throws: notifications are best effort.
  Future<void> start() async {
    _enabled = await _readBool(_keyEnabled, true);
    _previews = await _readBool(_keyPreviews, true);
    _asked = await _readBool(_keyAsked, false);
    _bannerDismissed = await _readBool(_keyBannerDismissed, false);
    try {
      final l10n = _strings();
      await _notifier.initialize(
        NotificationChannelNames(
          messages: l10n.notificationChannelMessages,
          calls: l10n.notificationChannelCalls,
          channels: l10n.notificationChannelChannels,
          openAction: l10n.notificationOpenAction,
        ),
      );
      _permission = await _notifier.permission();
    } catch (_) {
      // Plugin missing on this platform / build: the app works without.
      _supported = false;
      _permission = NotifierPermission.unsupported;
    }
    _subscriptions.add(_notifier.taps.listen(openFromData));
    try {
      final launch = await _notifier.takeLaunchTap();
      if (launch != null) openFromData(launch);
    } catch (_) {}
    _changed();
  }

  /// Called on every (re)connect of the hub: the device is surely
  /// registered then (also right after onboarding), so this is the moment
  /// for the one automatic permission prompt on mobile and for (re)registering
  /// the push token (a failed PUT is retried this way).
  Future<void> onConnected() async {
    if (!_enabled || !_supported) return;
    if (_permission != NotifierPermission.granted &&
        !_asked &&
        !_notifier.permissionNeedsUserGesture) {
      await _request();
    }
    await _registerPush();
  }

  /// The user tapped "Allow" (Settings or the banner): a user gesture, so
  /// this is also the only place the web prompt may come from.
  Future<void> requestPermission() async {
    await _request();
    await _registerPush();
  }

  /// Re-reads the OS permission (the user may have changed it in the system
  /// settings meanwhile) and registers push once it is granted. Called when
  /// the settings screen opens and when the app comes back to the
  /// foreground.
  Future<void> refreshPermission() async {
    if (!_supported) return;
    try {
      _permission = await _notifier.permission();
    } catch (_) {
      return;
    }
    _changed();
    if (_permission == NotifierPermission.granted &&
        pushStatus != PushStatus.registered) {
      await _registerPush();
    }
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    await _prefs.write(_keyEnabled, '$value');
    _changed();
    if (value) {
      if (_permission != NotifierPermission.granted) await _request();
      await _registerPush();
    } else {
      // Contract 1.1: DELETE so the server stops pushing to this device.
      await _push?.unregister();
      _changed();
    }
  }

  Future<void> setPreviews(bool value) async {
    _previews = value;
    await _prefs.write(_keyPreviews, '$value');
    _changed();
  }

  Future<void> dismissBanner() async {
    _bannerDismissed = true;
    await _prefs.write(_keyBannerDismissed, 'true');
    _changed();
  }

  /// Settings "test notification". False when nothing could be shown.
  Future<bool> showTest() async {
    if (_permission != NotifierPermission.granted) return false;
    final l10n = _strings();
    try {
      await _notifier.show(
        LocalNotification(
          target: null,
          title: 'Jay',
          body: l10n.notificationsTestBody,
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Opens what a notification (local or server push) points at.
  void openFromData(Map<String, Object?> data) {
    _openRoute(NotificationTarget.routeFor(data));
  }

  // -- Events -------------------------------------------------------------------

  /// A message the inbox just stored (decrypted, persisted).
  Future<void> onMessage(Message message) async {
    // A call-event is a log line, a tombstone has nothing to show.
    if (message.deleted || message.type == 'call-event') return;
    try {
      final conversation = await _directory.conversation(
        message.conversationId,
      );
      final kind = conversation.group
          ? NotificationKind.groupMessage
          : NotificationKind.message;
      final self = _directory.selfIdentityId;
      final sender = await _directory.contact(message.senderId);
      final target = NotificationTarget(kind, message.conversationId);
      if (_skip(
        target,
        fromSelf:
            self != null &&
            message.senderId.toLowerCase() == self.toLowerCase(),
        senderIsBot: sender.isBot,
      )) {
        return;
      }
      final text = notificationText(
        l10n: _strings(),
        kind: kind,
        title: conversation.title,
        previews: _previews,
        preview: _previewOf(message),
        senderName: sender.name,
      );
      await _show(target, text);
    } catch (_) {
      // A notification must never break message processing.
    }
  }

  /// A channel post that is new to this device.
  Future<void> onChannelPost(ChannelPostDto post) async {
    try {
      final target = NotificationTarget(
        NotificationKind.channelPost,
        post.channelId,
      );
      if (_skip(target, fromSelf: false)) return;
      final preview = switch (post.kind) {
        'image' => const MessagePreview.label(PreviewKind.photo),
        'poll' => const MessagePreview.label(PreviewKind.poll),
        _ => MessagePreview.text(post.body),
      };
      final text = notificationText(
        l10n: _strings(),
        kind: NotificationKind.channelPost,
        title: _directory.channelName(post.channelId),
        previews: _previews,
        preview: preview,
      );
      await _show(target, text);
    } catch (_) {}
  }

  /// A call started ringing on this device ([remoteDeviceId] is the caller).
  Future<void> onIncomingCall(String remoteDeviceId) async {
    try {
      final identity = await _directory.identityOfDevice(remoteDeviceId);
      final target = NotificationTarget(
        NotificationKind.incomingCall,
        identity,
      );
      if (_skip(target, fromSelf: false)) return;
      final caller = await _directory.contact(identity);
      final text = notificationText(
        l10n: _strings(),
        kind: NotificationKind.incomingCall,
        title: caller.name,
        previews: _previews,
      );
      _ringing = target;
      await _show(target, text);
    } catch (_) {}
  }

  /// The ringing stopped (answered, declined, missed): a stale "incoming
  /// call" must not stay in the tray.
  Future<void> onCallNotRinging() async {
    final ringing = _ringing;
    _ringing = null;
    if (ringing == null) return;
    try {
      await _notifier.cancel(ringing);
    } catch (_) {}
  }

  // -- Internals ----------------------------------------------------------------

  bool _skip(
    NotificationTarget target, {
    required bool fromSelf,
    bool senderIsBot = false,
  }) {
    if (!_supported || _permission != NotifierPermission.granted) return true;
    final reason = notificationSkip(
      enabled: _enabled,
      kind: target.kind,
      conversationId: target.conversationId,
      fromSelf: fromSelf,
      appFocused: _appFocused(),
      openConversationId: openConversationOf(_currentPath()),
      mute: target.kind == NotificationKind.channelPost
          ? MuteMode.off
          : _muteOf(target.conversationId),
      senderIsBot: senderIsBot,
    );
    return reason != null;
  }

  Future<void> _show(NotificationTarget target, NotificationText text) =>
      _notifier.show(
        LocalNotification(target: target, title: text.title, body: text.body),
      );

  static MessagePreview? _previewOf(Message message) {
    final body = message.body;
    if (body == null) return null;
    if (message.type == 'file') {
      try {
        final file = Attachment.decode(body);
        return MessagePreview.label(
          attachmentPreviewKind(file.name),
          caption: file.caption,
        );
      } catch (_) {
        return const MessagePreview.label(PreviewKind.file);
      }
    }
    return MessagePreview.text(body);
  }

  Future<void> _request() async {
    try {
      _permission = await _notifier.requestPermission();
    } catch (_) {
      _permission = NotifierPermission.denied;
    }
    _asked = true;
    await _prefs.write(_keyAsked, 'true');
    _changed();
  }

  Future<void> _registerPush() async {
    final provider = _pushProvider;
    final api = _api;
    final deviceId = _deviceId();
    if (!_enabled ||
        provider == null ||
        api == null ||
        deviceId == null ||
        deviceId.isEmpty ||
        _permission != NotifierPermission.granted) {
      return;
    }
    final push = _push ??= PushService(
      api,
      deviceId,
      provider: provider,
      locale: _locale,
      onOpened: openFromData,
      onForegroundPush: _onForegroundPush,
    );
    await push.register();
    _changed();
  }

  Future<bool> _readBool(String key, bool fallback) async {
    try {
      final value = await _prefs.read(key);
      return value == null ? fallback : value == 'true';
    } catch (_) {
      return fallback;
    }
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final s in _subscriptions) {
      s.cancel();
    }
    _push?.dispose();
    super.dispose();
  }
}

/// The conversation (or channel) whose screen is [path], null for any other
/// screen. Only the chat itself counts: its bot-talk settings page does not.
String? openConversationOf(String? path) {
  if (path == null) return null;
  final segments = Uri.parse(path).pathSegments;
  if (segments.length == 2 && segments[0] == 'chats') return segments[1];
  if (segments.length == 3 &&
      segments[0] == 'channels' &&
      segments[1] == 'feed') {
    return segments[2];
  }
  return null;
}
