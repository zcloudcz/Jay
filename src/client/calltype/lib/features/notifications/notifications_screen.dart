import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../calls/call_ring.dart';
import 'notification_service.dart';

/// Settings > Notifications (spec section 2): on/off (also registers or
/// unregisters the server push), message preview, a test notification and
/// what works on this platform right now.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  /// Android 14+ full-screen call permission (call ringing spec, section 2);
  /// null elsewhere.
  FullScreenIntentAccess? _fullScreen;
  bool _fullScreenAllowed = true;
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    // The user may come here straight from the system settings, where the
    // permission could have changed.
    unawaited(context.read<NotificationService>().refreshPermission());
    _fullScreen = context.read<FullScreenIntentAccess?>();
    if (_fullScreen != null) {
      unawaited(_checkFullScreen());
      // Back from the system setting the permission may have changed.
      _lifecycle = AppLifecycleListener(
        onResume: () => unawaited(_checkFullScreen()),
      );
    }
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    super.dispose();
  }

  Future<void> _checkFullScreen() async {
    final access = _fullScreen;
    if (access == null) return;
    var allowed = true;
    try {
      allowed = await access.canUseFullScreenIntent();
    } catch (_) {}
    if (mounted && allowed != _fullScreenAllowed) {
      setState(() => _fullScreenAllowed = allowed);
    }
  }

  Future<void> _requestFullScreen() async {
    try {
      await _fullScreen?.requestFullScreenIntent();
    } catch (_) {}
    await _checkFullScreen();
  }

  Future<void> _test() async {
    final service = context.read<NotificationService>();
    final messenger = ScaffoldMessenger.of(context);
    final failed = context.l10n.notificationsTestFailed;
    if (!await service.showTest()) {
      messenger.showSnackBar(SnackBar(content: Text(failed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<NotificationService>();
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final state = service.state;
    final needsPermission =
        state == NotificationState.permissionRequired ||
        state == NotificationState.permissionDenied;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsNotifications)),
      body: ListView(
        children: [
          ListTile(
            leading: Icon(_stateIcon(state), color: _stateColor(state, theme)),
            title: Text(notificationStateText(l10n, state)),
          ),
          if (needsPermission)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: FilledButton.icon(
                  icon: const Icon(Icons.notifications_active_outlined),
                  label: Text(l10n.notificationsAllow),
                  onPressed: service.requestPermission,
                ),
              ),
            ),
          const Divider(indent: 16, endIndent: 16),
          SwitchListTile(
            secondary: const Icon(Icons.notifications_outlined),
            title: Text(l10n.notificationsEnable),
            subtitle: Text(l10n.notificationsEnableSubtitle),
            value: service.enabled,
            onChanged: service.setEnabled,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.visibility_outlined),
            title: Text(l10n.notificationsPreview),
            subtitle: Text(l10n.notificationsPreviewSubtitle),
            value: service.previews,
            onChanged: service.enabled ? service.setPreviews : null,
          ),
          if (!_fullScreenAllowed)
            ListTile(
              leading: Icon(
                Icons.call_outlined,
                color: theme.colorScheme.error,
              ),
              title: Text(l10n.notificationsFullScreenTitle),
              subtitle: Text(l10n.notificationsFullScreenSubtitle),
              trailing: const Icon(Icons.open_in_new),
              onTap: _requestFullScreen,
            ),
          ListTile(
            leading: const Icon(Icons.send_outlined),
            title: Text(l10n.notificationsTest),
            enabled: service.enabled,
            onTap: service.enabled ? _test : null,
          ),
          const Divider(indent: 16, endIndent: 16),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              l10n.notificationsPrivacyNote,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static IconData _stateIcon(NotificationState state) => switch (state) {
    NotificationState.active => Icons.notifications_active,
    NotificationState.off => Icons.notifications_off_outlined,
    NotificationState.unsupported ||
    NotificationState.permissionDenied => Icons.block,
    _ => Icons.notifications_outlined,
  };

  static Color _stateColor(NotificationState state, ThemeData theme) =>
      switch (state) {
        NotificationState.permissionDenied ||
        NotificationState.unsupported => theme.colorScheme.error,
        NotificationState.off => theme.colorScheme.onSurfaceVariant,
        _ => theme.colorScheme.primary,
      };
}

/// The status line of each [NotificationState].
String notificationStateText(AppLocalizations l10n, NotificationState state) =>
    switch (state) {
      NotificationState.off => l10n.notificationsStateOff,
      NotificationState.unsupported => l10n.notificationsStateUnsupported,
      NotificationState.permissionDenied =>
        l10n.notificationsStatePermissionDenied,
      NotificationState.permissionRequired =>
        l10n.notificationsStatePermissionRequired,
      NotificationState.localOnly => l10n.notificationsStateLocalOnly,
      NotificationState.pushNotConfigured =>
        l10n.notificationsStatePushNotConfigured,
      NotificationState.pushPending => l10n.notificationsStatePushPending,
      NotificationState.active => l10n.notificationsStateActive,
    };

/// One-time banner on the chat list, web only: the browser accepts the
/// permission prompt only from a click, never on page load (spec section 2),
/// so the app offers the click here instead of prompting by itself.
class NotificationPermissionBanner extends StatelessWidget {
  const NotificationPermissionBanner({super.key});

  @override
  Widget build(BuildContext context) {
    // Optional so screens pumped without it (tests) still build.
    final service = context.watch<NotificationService?>();
    if (service == null || !service.showPermissionBanner) {
      return const SizedBox.shrink();
    }
    final l10n = context.l10n;
    return MaterialBanner(
      leading: const Icon(Icons.notifications_outlined),
      content: Text(l10n.notificationsBannerText),
      actions: [
        TextButton(
          onPressed: service.dismissBanner,
          child: Text(l10n.notificationsBannerDismiss),
        ),
        FilledButton(
          onPressed: service.requestPermission,
          child: Text(l10n.notificationsBannerAllow),
        ),
      ],
    );
  }
}
