import 'dart:typed_data';

import 'package:calltype/core/storage/database.dart';
import 'package:calltype/core/storage/secure_storage.dart';
import 'package:calltype/features/channels/channel_create_screen.dart';
import 'package:calltype/features/channels/channel_notice.dart';
import 'package:calltype/features/channels/channel_profile_screen.dart';
import 'package:calltype/features/channels/channel_screen.dart';
import 'package:calltype/features/channels/channels_controller.dart';
import 'package:calltype/features/channels/updates_screen.dart';
import 'package:calltype/features/contacts/contacts_controller.dart';
import 'package:calltype_core/network/channel_dtos.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
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

  /// Lets real-zone work (drift, fake API futures) finish, then rebuilds.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // dialog animation
  }

  testWidgets('admins screen lists current admins (contact name or short '
      'id) and removes one', (tester) async {
    final h = (await tester.runAsync(() async => ChannelHarness()))!;
    final contacts = ContactsController(database: h.db);
    await tester.runAsync(
      () => h.db
          .into(h.db.contacts)
          .insert(
            ContactsCompanion.insert(
              deviceId: 'd1',
              userHandle: 'CT-ALIC-E001',
              displayName: const Value('Alice'),
              identityKey: Uint8List(0),
              addedAt: DateTime.now(),
            ),
          ),
    );
    h.api.admins = const [
      ChannelAdminDto(deviceId: 'd1'),
      // Appointed earlier, contact deleted since: only the id is known.
      ChannelAdminDto(deviceId: 'abcdef12-0000-4000-8000-000000000000'),
    ];
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ChannelsController>.value(value: h.controller),
          ChangeNotifierProvider.value(value: contacts),
        ],
        child: const MaterialApp(home: ChannelAdminsScreen(channelId: 'c1')),
      ),
    );
    await settle(tester);

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('abcdef12'), findsOneWidget);
    expect(find.byTooltip('Remove admin'), findsNWidgets(2));
    // Alice is an admin already → not offered again.
    expect(find.byTooltip('Make admin'), findsNothing);

    await tester.tap(find.byTooltip('Remove admin').first);
    await settle(tester);

    expect(h.api.calls, contains('admin d1 false'));
    expect(find.byTooltip('Remove admin'), findsOneWidget);
    expect(find.byTooltip('Make admin'), findsOneWidget); // Alice, again

    await tester.pumpWidget(const SizedBox());
    contacts.dispose();
    await tearDownHarness(tester, h);
  });

  group('channel profile owner actions', () {
    Future<ChannelHarness> pumpProfile(
      WidgetTester tester, {
      String? role,
    }) async {
      final h = (await tester.runAsync(() async => ChannelHarness()))!;
      final info = ChannelInfo(
        channelId: 'c1',
        handle: 'CH-NEWS-0001',
        name: 'News',
        role: role,
      );
      h.api.profiles[info.handle] = info;
      await tester.runAsync(() async {
        h.api.mine = [info];
        await h.controller.sync();
      });
      await tester.pumpWidget(
        ChangeNotifierProvider<ChannelsController>.value(
          value: h.controller,
          child: MaterialApp.router(
            routerConfig: GoRouter(
              routes: [
                GoRoute(
                  path: '/',
                  builder: (_, _) =>
                      const ChannelProfileScreen(handle: 'CH-NEWS-0001'),
                ),
                GoRoute(
                  path: '/updates',
                  builder: (_, _) => const Text('updates tab'),
                ),
              ],
            ),
          ),
        ),
      );
      await settle(tester);
      return h;
    }

    testWidgets('a follower sees none of them', (tester) async {
      final h = await pumpProfile(tester);
      expect(find.text('Edit channel'), findsNothing);
      expect(find.text('Manage admins'), findsNothing);
      expect(find.text('Delete channel'), findsNothing);
      await tearDownHarness(tester, h);
    });

    testWidgets('an admin may edit, but not manage admins or delete', (
      tester,
    ) async {
      final h = await pumpProfile(tester, role: 'admin');
      expect(find.text('Edit channel'), findsOneWidget);
      expect(find.text('Manage admins'), findsNothing);
      expect(find.text('Delete channel'), findsNothing);
      await tearDownHarness(tester, h);
    });

    testWidgets('owner edits the name: only the changed field is sent', (
      tester,
    ) async {
      final h = await pumpProfile(tester, role: 'owner');
      await tester.tap(find.text('Edit channel'));
      await settle(tester);
      await tester.enterText(find.byType(TextFormField).first, ' Renamed ');
      await tester.tap(find.text('Save'));
      await settle(tester);

      expect(h.api.calls, contains('patch c1 name=Renamed description=null'));
      expect(find.text('Renamed'), findsOneWidget);
      await tearDownHarness(tester, h);
    });

    testWidgets('owner deletes the channel only after confirming', (
      tester,
    ) async {
      final h = await pumpProfile(tester, role: 'owner');
      await tester.tap(find.text('Delete channel'));
      await settle(tester);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(h.api.calls.where((c) => c.startsWith('delete')), isEmpty);

      await tester.tap(find.text('Delete channel'));
      await settle(tester);
      await tester.tap(find.text('Delete'));
      await settle(tester);

      expect(h.api.calls, contains('delete c1'));
      expect(h.controller.channels, isEmpty);
      expect(find.text('updates tab'), findsOneWidget);
      await tearDownHarness(tester, h);
    });
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
