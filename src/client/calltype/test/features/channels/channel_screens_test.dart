import 'package:calltype/core/storage/secure_storage.dart';
import 'package:calltype/features/channels/channel_create_screen.dart';
import 'package:calltype/features/channels/channel_notice.dart';
import 'package:calltype/features/channels/channel_screen.dart';
import 'package:calltype/features/channels/channels_controller.dart';
import 'package:calltype/features/channels/updates_screen.dart';
import 'package:calltype_core/network/channel_dtos.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'fake_channels.dart';

void main() {
  /// Pumps [child] with a controller that lists one channel with [role].
  Future<ChannelHarness> pumpWithChannel(
    WidgetTester tester,
    Widget child, {
    String? role,
  }) async {
    // Built inside runAsync so the controller's hub subscriptions live in
    // the real async zone; in the fake-clock zone their DB work would only
    // advance while the test pumps.
    final h = (await tester.runAsync(() async => ChannelHarness()))!;
    await tester.runAsync(() async {
      h.api.mine = [
        ChannelInfo(
          channelId: 'c1',
          handle: 'CH-NEWS-0001',
          name: 'News',
          role: role,
        ),
      ];
      await h.controller.sync();
    });
    await tester.pumpWidget(
      ChangeNotifierProvider<ChannelsController>.value(
        value: h.controller,
        child: MaterialApp(home: child),
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
    // Drift tears a cancelled watch-stream down on a timer that lives in the
    // test's fake clock; let it fire or db.close() waits forever.
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(h.dispose);
  }

  testWidgets('follower sees NO input field, but the non-E2E notice', (
    tester,
  ) async {
    final h = await pumpWithChannel(
      tester,
      const ChannelScreen(channelId: 'c1'),
    );
    expect(find.text('News'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byKey(const Key('channel-compose-bar')), findsNothing);
    expect(find.text(channelPublicNotice), findsOneWidget);
    await tearDownHarness(tester, h);
  });

  testWidgets('admin sees the compose bar (text, image, poll)', (tester) async {
    final h = await pumpWithChannel(
      tester,
      const ChannelScreen(channelId: 'c1'),
      role: 'admin',
    );
    expect(find.byKey(const Key('channel-compose-bar')), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byTooltip('Post image (max 2 MiB)'), findsOneWidget);
    expect(find.byTooltip('Post poll'), findsOneWidget);
    expect(find.text(channelPublicNotice), findsOneWidget);
    await tearDownHarness(tester, h);
  });

  testWidgets('Updates tab lists channels with the non-E2E notice and an '
      'unread badge in the navigation', (tester) async {
    final h = await pumpWithChannel(tester, const UpdatesScreen());
    await tester.runAsync(() => h.emitPost(postEvent('p1')));
    await tester.pump();
    expect(find.text('News'), findsOneWidget);
    expect(find.text(channelPublicNotice), findsOneWidget);
    Finder badgeIn(Type type) =>
        find.descendant(of: find.byType(type), matching: find.text('1'));
    expect(badgeIn(ListTile), findsOneWidget);
    expect(badgeIn(NavigationBar), findsOneWidget);
    await tearDownHarness(tester, h);
  });

  group('create-channel gate', () {
    Future<void> pumpCreate(WidgetTester tester, ChannelHarness h) async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider.value(value: SecureStorage()),
            ChangeNotifierProvider<ChannelsController>.value(
              value: h.controller,
            ),
          ],
          child: const MaterialApp(home: ChannelCreateScreen()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('device without an account gets an explanation and a link to '
        'registration instead of a form', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final h = ChannelHarness();
      await pumpCreate(tester, h);
      expect(find.textContaining('requires a registered account'), findsOne);
      expect(find.text('Register or log in'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.text(channelPublicNotice), findsOneWidget);
      await tearDownHarness(tester, h);
    });

    testWidgets('device with a linked account gets the form', (tester) async {
      FlutterSecureStorage.setMockInitialValues({'ct_account_id': 'acc-1'});
      final h = ChannelHarness();
      await pumpCreate(tester, h);
      expect(find.text('Create channel'), findsOneWidget);
      expect(find.byType(TextField), findsNWidgets(2));
      expect(find.text('Register or log in'), findsNothing);
      await tearDownHarness(tester, h);
    });
  });
}
