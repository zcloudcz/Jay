import 'package:calltype/features/calls/call_ring.dart';
import 'package:calltype/features/notifications/local_notifier.dart';
import 'package:calltype/features/notifications/notification_service.dart';
import 'package:calltype/features/notifications/notifications_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../helpers/localized_app.dart';
import 'fake_notifications.dart';

/// Settings > Notifications against the fake platform layer.
void main() {
  Future<NotificationHarness> pump(
    WidgetTester tester, {
    FakeNotifier? notifier,
    FakePushProvider? provider,
    Widget child = const NotificationsScreen(),
    Locale locale = const Locale('en'),
    String? deviceId = 'dev-1',
  }) async {
    final h = NotificationHarness(
      notifier: notifier,
      provider: provider,
      deviceId: deviceId,
    );
    await h.service.start();
    await tester.pumpWidget(
      ChangeNotifierProvider<NotificationService>.value(
        value: h.service,
        child: localizedApp(home: child, locale: locale),
      ),
    );
    await tester.pumpAndSettle();
    return h;
  }

  testWidgets('defaults: on, previews on; switches persist', (tester) async {
    final h = await pump(tester, provider: FakePushProvider());
    expect(find.text(l10nEn.settingsNotifications), findsOneWidget);
    final switches = tester
        .widgetList<SwitchListTile>(find.byType(SwitchListTile))
        .toList();
    expect(switches.map((s) => s.value), [true, true]);

    await tester.tap(find.text(l10nEn.notificationsPreview));
    await tester.pumpAndSettle();
    expect(h.service.previews, isFalse);
    expect(h.prefs.values['ct_notifications_previews'], 'false');

    await tester.tap(find.text(l10nEn.notificationsEnable));
    await tester.pumpAndSettle();
    expect(h.service.enabled, isFalse);
    expect(find.text(l10nEn.notificationsStateOff), findsOneWidget);
    // Preview switch is disabled while notifications are off.
    final preview = tester
        .widgetList<SwitchListTile>(find.byType(SwitchListTile))
        .last;
    expect(preview.onChanged, isNull);
  });

  testWidgets('status: active once the push token is registered', (
    tester,
  ) async {
    // Opening the screen re-reads the permission and registers when allowed.
    final h = await pump(tester, provider: FakePushProvider());
    expect(find.text(l10nEn.notificationsStateActive), findsOneWidget);
    expect(h.api.calls, ['PUT dev-1 fcm tok cs']);
  });

  testWidgets('status: push pending while the device has no id yet', (
    tester,
  ) async {
    await pump(tester, provider: FakePushProvider(), deviceId: null);
    expect(find.text(l10nEn.notificationsStatePushPending), findsOneWidget);
  });

  testWidgets('desktop shows "while running" only', (tester) async {
    await pump(tester);
    expect(find.text(l10nEn.notificationsStateLocalOnly), findsOneWidget);
  });

  testWidgets('denied permission: explanation and an Allow button', (
    tester,
  ) async {
    final notifier = FakeNotifier(
      current: NotifierPermission.notDetermined,
      answer: NotifierPermission.denied,
      needsGesture: true,
    );
    await pump(tester, notifier: notifier);
    expect(
      find.text(l10nEn.notificationsStatePermissionRequired),
      findsOneWidget,
    );

    await tester.tap(find.text(l10nEn.notificationsAllow));
    await tester.pumpAndSettle();
    expect(notifier.prompts, 1);
    expect(
      find.text(l10nEn.notificationsStatePermissionDenied),
      findsOneWidget,
    );
  });

  testWidgets('test notification: shown, or a snackbar when it cannot be', (
    tester,
  ) async {
    final h = await pump(tester);
    await tester.tap(find.text(l10nEn.notificationsTest));
    await tester.pumpAndSettle();
    expect(h.notifier.shown, hasLength(1));

    h.notifier.current = NotifierPermission.denied;
    await h.service.refreshPermission();
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10nEn.notificationsTest));
    await tester.pumpAndSettle();
    expect(find.text(l10nEn.notificationsTestFailed), findsOneWidget);
  });

  testWidgets('web banner: visible until answered, Not now hides it', (
    tester,
  ) async {
    final h = await pump(
      tester,
      notifier: FakeNotifier(
        current: NotifierPermission.notDetermined,
        needsGesture: true,
      ),
      child: const Scaffold(body: NotificationPermissionBanner()),
    );
    expect(find.text(l10nEn.notificationsBannerText), findsOneWidget);

    await tester.tap(find.text(l10nEn.notificationsBannerDismiss));
    await tester.pumpAndSettle();
    expect(find.text(l10nEn.notificationsBannerText), findsNothing);
    expect(h.service.showPermissionBanner, isFalse);
  });

  testWidgets('banner is absent on mobile and without the service', (
    tester,
  ) async {
    await pump(
      tester,
      notifier: FakeNotifier(current: NotifierPermission.notDetermined),
      child: const Scaffold(body: NotificationPermissionBanner()),
    );
    expect(find.text(l10nEn.notificationsBannerText), findsNothing);

    await tester.pumpWidget(
      localizedApp(home: const Scaffold(body: NotificationPermissionBanner())),
    );
    expect(find.byType(MaterialBanner), findsNothing);
  });

  testWidgets('Android 14+: a missing full-screen call permission shows a '
      'row that opens the system setting', (tester) async {
    final access = FakeFullScreenAccess()..allowed = false;
    final h = NotificationHarness(provider: FakePushProvider());
    await h.service.start();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<NotificationService>.value(value: h.service),
          Provider<FullScreenIntentAccess?>.value(value: access),
        ],
        child: localizedApp(home: const NotificationsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(l10nEn.notificationsFullScreenTitle), findsOneWidget);

    access.allowed = true;
    await tester.tap(find.text(l10nEn.notificationsFullScreenTitle));
    await tester.pumpAndSettle();
    expect(access.requests, 1);
    expect(find.text(l10nEn.notificationsFullScreenTitle), findsNothing);
  });

  testWidgets('the full-screen row is absent when allowed or not Android', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text(l10nEn.notificationsFullScreenTitle), findsNothing);
  });

  testWidgets('renders in Czech and right-to-left Arabic', (tester) async {
    await pump(tester, locale: const Locale('cs'));
    expect(find.text('Oznámení'), findsOneWidget);
    await pump(tester, locale: const Locale('ar'));
    expect(tester.takeException(), isNull);
  });
}

class FakeFullScreenAccess implements FullScreenIntentAccess {
  bool allowed = true;
  int requests = 0;
  @override
  Future<bool> canUseFullScreenIntent() async => allowed;
  @override
  Future<void> requestFullScreenIntent() async => requests++;
}
