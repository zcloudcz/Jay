import 'package:calltype_core/crypto/key_manager.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype/core/storage/secure_storage.dart';
import 'package:calltype/features/channels/channel_screen.dart';
import 'package:calltype/features/channels/channels_controller.dart';
import 'package:calltype/features/channels/updates_screen.dart';
import 'package:calltype/features/onboarding/onboarding_controller.dart';
import 'package:calltype/features/onboarding/onboarding_screen.dart';
import 'package:calltype/l10n/l10n.dart';
import 'package:calltype_core/network/channel_dtos.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../features/channels/fake_channels.dart';
import '../helpers/localized_app.dart';

/// Pumps real screens under several locales. A layout overflow is reported
/// by Flutter as an exception, so `takeException() == null` doubles as a
/// cheap "the longer translation still fits a 360 px wide phone" check —
/// NOT a substitute for looking at the real screens.
void main() {
  // A phone-sized surface: overflow caused by long German / Russian labels
  // would not show on the default 800 px wide test window.
  void usePhoneSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpOnboarding(WidgetTester tester, Locale locale) async {
    usePhoneSurface(tester);
    final storage = SecureStorage();
    final controller = OnboardingController(
      apiClient: ApiClient(baseUrl: 'https://test.calltype.test'),
      secureStorage: storage,
      keyManager: KeyManager(secureStorage: storage),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: localizedApp(home: const OnboardingScreen(), locale: locale),
      ),
    );
    await tester.pump();
  }

  /// Same harness as channel_screens_test: one channel this device
  /// administers, so the compose bar (the tightest row) is on screen.
  Future<ChannelHarness> pumpChannel(
    WidgetTester tester,
    Widget screen,
    Locale locale,
  ) async {
    usePhoneSurface(tester);
    final h = (await tester.runAsync(() async => ChannelHarness()))!;
    await tester.runAsync(() async {
      h.api.mine = [
        ChannelInfo(
          channelId: 'c1',
          handle: 'CH-NEWS-0001',
          name: 'News',
          role: 'admin',
        ),
      ];
      await h.controller.sync();
    });
    await tester.pumpWidget(
      ChangeNotifierProvider<ChannelsController>.value(
        value: h.controller,
        child: localizedApp(home: screen, locale: locale),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    return h;
  }

  Future<void> tearDownHarness(WidgetTester tester, ChannelHarness h) async {
    await tester.pumpWidget(const SizedBox());
    // See channel_screens_test: drift's watch-stream teardown timer.
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(h.dispose);
  }

  TextDirection directionOf(WidgetTester tester, Type screen) =>
      Directionality.of(tester.element(find.byType(screen)));

  for (final code in ['cs', 'de', 'ar']) {
    final locale = Locale(code);
    final l10n = lookupAppLocalizations(locale);
    final expectedDirection = code == 'ar'
        ? TextDirection.rtl
        : TextDirection.ltr;

    testWidgets('onboarding renders in $code', (tester) async {
      await pumpOnboarding(tester, locale);
      expect(find.text(l10n.onboardingGetStarted), findsOneWidget);
      expect(find.text(l10n.onboardingTagline), findsOneWidget);
      expect(find.text(l10nEn.onboardingGetStarted), findsNothing);
      expect(find.text('Jay'), findsOneWidget); // product name untranslated
      expect(directionOf(tester, OnboardingScreen), expectedDirection);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Updates tab renders in $code', (tester) async {
      final h = await pumpChannel(tester, const UpdatesScreen(), locale);
      expect(find.text(l10n.channelPublicNotice), findsOneWidget);
      expect(find.text(l10n.channelNew), findsOneWidget);
      // Both bottom-navigation labels, translated.
      expect(find.text(l10n.navChats), findsOneWidget);
      expect(find.text(l10n.navUpdates), findsWidgets);
      expect(
        find.text('CH-NEWS-0001 · ${l10n.channelRoleAdmin}'),
        findsOneWidget,
      );
      expect(directionOf(tester, UpdatesScreen), expectedDirection);
      expect(tester.takeException(), isNull);
      await tearDownHarness(tester, h);
    });

    testWidgets('channel feed with compose bar renders in $code', (
      tester,
    ) async {
      final h = await pumpChannel(
        tester,
        const ChannelScreen(channelId: 'c1'),
        locale,
      );
      expect(find.text(l10n.channelPublicNotice), findsOneWidget);
      expect(find.text(l10n.channelNoPosts), findsOneWidget);
      expect(find.byTooltip(l10n.channelPostPoll), findsOneWidget);
      expect(find.text(l10n.channelComposeHint), findsOneWidget);
      expect(directionOf(tester, ChannelScreen), expectedDirection);
      expect(tester.takeException(), isNull);
      await tearDownHarness(tester, h);
    });
  }

  testWidgets('a language we do not ship (Swahili) falls back to English', (
    tester,
  ) async {
    await pumpOnboarding(tester, const Locale('sw'));
    expect(find.text('Get Started'), findsOneWidget);
    expect(directionOf(tester, OnboardingScreen), TextDirection.ltr);
    expect(tester.takeException(), isNull);
  });
}
