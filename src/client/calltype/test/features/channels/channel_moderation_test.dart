import 'package:calltype/core/storage/secure_storage.dart';
import 'package:calltype/features/channels/channel_create_screen.dart';
import 'package:calltype/features/channels/channel_moderation.dart';
import 'package:calltype/features/channels/channel_profile_screen.dart';
import 'package:calltype/features/channels/channel_screen.dart';
import 'package:calltype/features/channels/channels_controller.dart';
import 'package:calltype/features/contacts/contacts_controller.dart';
import 'package:calltype_core/network/channel_dtos.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:calltype/l10n/l10n.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

import '../../helpers/localized_app.dart';
import 'fake_channels.dart';

/// Channel moderation in the app (contract 2026-11-05 section 7). Server
/// JSON shapes in the fake come from the contract.
void main() {
  final launched = <Uri>[];
  setUp(() {
    launched.clear();
    channelUrlLauncher = (uri) async {
      launched.add(uri);
      return true;
    };
  });

  /// Lets real-zone work (drift, fake API futures) finish, then rebuilds.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // dialog animation
  }

  Future<void> tearDownHarness(WidgetTester tester, ChannelHarness h) async {
    await tester.pumpWidget(const SizedBox());
    // Drift tears a cancelled watch-stream down on a timer that lives in the
    // test's fake clock; let it fire or db.close() waits forever.
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(h.dispose);
  }

  /// Harness whose `/mine` lists [info]; synced before pumping.
  Future<ChannelHarness> harness(
    WidgetTester tester,
    ChannelInfo info, {
    void Function(ChannelHarness h)? setup,
  }) async {
    final h = (await tester.runAsync(() async => ChannelHarness()))!;
    h.api.profiles[info.handle] = info;
    setup?.call(h);
    await tester.runAsync(() async {
      h.api.mine = [info];
      await h.controller.sync();
    });
    return h;
  }

  Future<void> pump(
    WidgetTester tester,
    ChannelHarness h,
    Widget child, {
    List<SingleChildWidget> extra = const [],
  }) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ChannelsController>.value(value: h.controller),
          ...extra,
        ],
        child: localizedApp(home: child),
      ),
    );
    await settle(tester);
  }

  ChannelInfo channelInfo({
    String? role,
    String status = 'active',
    DateTime? suspendedUntil,
  }) => ChannelInfo(
    channelId: 'c1',
    handle: 'CH-NEWS-0001',
    name: 'News',
    role: role,
    status: status,
    suspendedUntil: suspendedUntil,
  );

  group('report dialog', () {
    Future<ChannelHarness> openDialog(WidgetTester tester) async {
      final h = await harness(tester, channelInfo());
      await pump(
        tester,
        h,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => reportChannelDialog(context, 'c1', postId: 'p1'),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await settle(tester);
      return h;
    }

    FilledButton submit(WidgetTester tester) => tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, l10nEn.channelReportSubmit),
    );

    testWidgets('illegal content needs good faith; e-mail optional but '
        'valid; receipt shows the report number', (tester) async {
      final h = await openDialog(tester);
      expect(find.text(l10nEn.channelReportCategoryTerms), findsOneWidget);
      expect(find.text(l10nEn.channelReportCategorySpam), findsOneWidget);
      // Good faith and e-mail appear only for illegal content.
      expect(find.byKey(const Key('report-good-faith')), findsNothing);

      await tester.tap(find.byKey(const Key('report-category-illegal')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('report-reason')), 'hate');
      await tester.pump();
      expect(submit(tester).onPressed, isNull, reason: 'no good faith yet');

      await tester.tap(find.byKey(const Key('report-good-faith')));
      await tester.pump();
      expect(submit(tester).onPressed, isNotNull);

      await tester.enterText(find.byKey(const Key('report-email')), 'nope');
      await tester.pump();
      expect(find.text(l10nEn.channelReportEmailInvalid), findsOneWidget);
      expect(submit(tester).onPressed, isNull);
      await tester.enterText(find.byKey(const Key('report-email')), 'a@b.cz');
      await tester.pump();

      await tester.tap(find.text(l10nEn.channelReportSubmit));
      await settle(tester);
      expect(h.api.lastReport, {
        'postId': 'p1',
        'reason': 'hate',
        'category': 'illegal',
        'contactEmail': 'a@b.cz',
        'goodFaith': true,
      });
      expect(find.text(l10nEn.channelReportReceipt('41')), findsOneWidget);
      await tearDownHarness(tester, h);
    });

    testWidgets('default category terms sends no e-mail nor good faith; '
        'the rules link opens the English page', (tester) async {
      final h = await openDialog(tester);
      await tester.tap(find.text(l10nEn.channelRules));
      await settle(tester);
      expect(
        launched.single.toString(),
        'https://jay.zcloud.cz/legal/channels-en.html',
      );

      await tester.enterText(find.byKey(const Key('report-reason')), 'spam!');
      await tester.pump();
      await tester.tap(find.text(l10nEn.channelReportSubmit));
      await settle(tester);
      expect(h.api.lastReport!['category'], 'terms');
      expect(h.api.lastReport!['contactEmail'], isNull);
      expect(h.api.lastReport!['goodFaith'], false);
      await tearDownHarness(tester, h);
    });

    testWidgets('an old server without receipt: plain confirmation', (
      tester,
    ) async {
      final h = await openDialog(tester);
      h.api.reportId = 0;
      await tester.enterText(find.byKey(const Key('report-reason')), 'x');
      await tester.pump();
      await tester.tap(find.text(l10nEn.channelReportSubmit));
      await settle(tester);
      expect(find.text(l10nEn.channelReportSent), findsOneWidget);
      await tearDownHarness(tester, h);
    });
  });

  testWidgets('Reports I filed lists number, category and status', (
    tester,
  ) async {
    final h = await harness(
      tester,
      channelInfo(),
      setup: (h) => h.api.myReports = [
        MyReport.fromJson({
          'reportId': 7,
          'channelId': 'c1',
          'channelName': 'News',
          'channelHandle': 'CH-NEWS-0001',
          'postId': null,
          'category': 'spam',
          'createdAt': '2026-11-05T10:00:00Z',
          'status': 'open',
          'resolvedAt': null,
        }),
        MyReport.fromJson({
          'reportId': 8,
          'channelId': 'c2',
          'channelName': 'Gone',
          'channelHandle': 'CH-GONE-0001',
          'postId': 'p1',
          'category': 'illegal',
          'createdAt': '2026-11-04T10:00:00Z',
          'status': 'actioned',
          'resolvedAt': '2026-11-05T09:00:00Z',
        }),
        MyReport.fromJson({
          'reportId': 9,
          'channelId': 'c3',
          'channelName': 'Fine',
          'channelHandle': 'CH-FINE-0001',
          'postId': null,
          'category': 'terms',
          'createdAt': '2026-11-03T10:00:00Z',
          'status': 'dismissed',
          'resolvedAt': '2026-11-04T09:00:00Z',
        }),
      ],
    );
    await pump(tester, h, const MyReportsScreen());
    expect(find.text('News'), findsOneWidget);
    expect(find.text('Gone'), findsOneWidget);
    expect(find.text(l10nEn.channelReportStatusOpen), findsOneWidget);
    expect(find.text(l10nEn.channelReportStatusActioned), findsOneWidget);
    expect(find.text(l10nEn.channelReportStatusDismissed), findsOneWidget);
    expect(
      find.textContaining(l10nEn.channelMyReportNumber('7')),
      findsOneWidget,
    );
    await tearDownHarness(tester, h);
  });

  group('feed', () {
    testWidgets('a bot post carries the BOT label', (tester) async {
      final h = await harness(tester, channelInfo());
      await tester.runAsync(() async {
        await h.emitPost(postEvent('p1', byBot: true));
        await h.emitPost(
          postEvent('p2', createdAt: '2026-09-17T11:00:00.000Z'),
        );
      });
      await pump(tester, h, const ChannelScreen(channelId: 'c1'));
      expect(find.byKey(const Key('post-bot-badge')), findsOneWidget);
      await tearDownHarness(tester, h);
    });

    testWidgets('403 channel_suspended shows the suspended state, not an '
        'error', (tester) async {
      final h = await harness(
        tester,
        channelInfo(),
        setup: (h) => h.api.suspendedFeeds.add('c1'),
      );
      await pump(tester, h, const ChannelScreen(channelId: 'c1'));
      expect(find.text(l10nEn.channelSuspendedFeed), findsOneWidget);
      expect(find.byKey(const Key('channel-suspended-banner')), findsOneWidget);
      await tearDownHarness(tester, h);
    });

    testWidgets('owner of a suspended channel reads posts but cannot '
        'publish', (tester) async {
      final until = DateTime.now().toUtc().add(const Duration(days: 7));
      final h = await harness(
        tester,
        channelInfo(role: 'owner', status: 'suspended', suspendedUntil: until),
      );
      await tester.runAsync(() => h.emitPost(postEvent('p1')));
      await pump(tester, h, const ChannelScreen(channelId: 'c1'));
      expect(find.text('hello p1'), findsOneWidget);
      expect(find.byKey(const Key('channel-suspended-banner')), findsOneWidget);
      expect(find.byKey(const Key('channel-compose-bar')), findsNothing);
      await tearDownHarness(tester, h);
    });

    testWidgets('publisher posts, and may delete only its own posts', (
      tester,
    ) async {
      final h = await harness(tester, channelInfo(role: 'publisher'));
      await tester.runAsync(() async {
        await h.emitPost(postEvent('theirs'));
        await h.controller.publish('c1', kind: 'text', body: 'mine');
        // A refresh overwrites with server data (no author): the mark stays.
        await h.controller.refresh('c1');
      });
      await pump(tester, h, const ChannelScreen(channelId: 'c1'));
      expect(find.byKey(const Key('channel-compose-bar')), findsOneWidget);

      Future<bool> canDelete(String text) async {
        final card = find.ancestor(
          of: find.text(text),
          matching: find.byType(Card),
        );
        await tester.tap(
          find.descendant(of: card, matching: find.byTooltip('Post options')),
        );
        await settle(tester);
        final found = find.text(l10nEn.channelDeletePost).evaluate().isNotEmpty;
        await tester.tapAt(Offset.zero); // close the menu
        await settle(tester);
        return found;
      }

      expect(await canDelete('mine'), isTrue);
      expect(await canDelete('hello theirs'), isFalse);
      await tearDownHarness(tester, h);
    });
  });

  group('profile', () {
    Future<ChannelHarness> pumpProfile(
      WidgetTester tester,
      ChannelInfo info, {
      void Function(ChannelHarness h)? setup,
    }) async {
      final h = await harness(tester, info, setup: setup);
      await tester.pumpWidget(
        ChangeNotifierProvider<ChannelsController>.value(
          value: h.controller,
          child: localizedApp(
            router: GoRouter(
              routes: [
                GoRoute(
                  path: '/',
                  builder: (_, _) =>
                      const ChannelProfileScreen(handle: 'CH-NEWS-0001'),
                ),
              ],
            ),
          ),
        ),
      );
      await settle(tester);
      return h;
    }

    testWidgets('publisher: no edit / admins / delete, but the moderation '
        'statements with rule link and redress text', (tester) async {
      final h = await pumpProfile(
        tester,
        channelInfo(role: 'publisher'),
        setup: (h) => h.api.statements = [
          ModerationStatement.fromJson({
            'decisionId': 3,
            'action': 'remove_post',
            'postId': 'p1',
            'ground': 'terms',
            'rule': 'K3',
            'legalGround': null,
            'explanation': 'Advertising for a scam.',
            'suspendedUntil': null,
            'basedOnReports': true,
            'automated': false,
            'createdAt': '2026-11-05T10:00:00Z',
          }),
        ],
      );
      expect(find.text('Edit channel'), findsNothing);
      expect(find.text('Manage admins'), findsNothing);
      expect(find.text('Delete channel'), findsNothing);

      await tester.scrollUntilVisible(
        find.text(l10nEn.channelModerationRedress),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(l10nEn.channelModerationTitle), findsOneWidget);
      expect(find.text(l10nEn.channelModerationRemovePost), findsOneWidget);
      expect(find.text('Advertising for a scam.'), findsOneWidget);
      expect(find.text(l10nEn.channelModerationBasedOnReports), findsOneWidget);
      await tester.tap(find.text(l10nEn.channelModerationRule('K3')));
      await settle(tester);
      expect(
        launched.single.toString(),
        'https://jay.zcloud.cz/legal/channels-en.html#K3',
      );
      await tearDownHarness(tester, h);
    });

    testWidgets('a follower sees no moderation section', (tester) async {
      final h = await pumpProfile(tester, channelInfo());
      expect(h.api.calls.where((c) => c.startsWith('moderation')), isEmpty);
      expect(find.text(l10nEn.channelModerationTitle), findsNothing);
      await tearDownHarness(tester, h);
    });

    testWidgets('suspended channel: banner with date for everyone, no new '
        'follow', (tester) async {
      final until = DateTime.utc(2099, 1, 2, 3, 4);
      final info = channelInfo(status: 'suspended', suspendedUntil: until);
      // A visitor, not yet following: /mine does not list the channel.
      final h = (await tester.runAsync(() async => ChannelHarness()))!;
      h.api.profiles[info.handle] = info;
      await tester.pumpWidget(
        ChangeNotifierProvider<ChannelsController>.value(
          value: h.controller,
          child: localizedApp(
            router: GoRouter(
              routes: [
                GoRoute(
                  path: '/',
                  builder: (_, _) =>
                      const ChannelProfileScreen(handle: 'CH-NEWS-0001'),
                ),
              ],
            ),
          ),
        ),
      );
      await settle(tester);
      expect(find.byKey(const Key('channel-suspended-banner')), findsOneWidget);
      expect(find.textContaining('2099'), findsOneWidget);
      final follow = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Follow'),
      );
      expect(follow.onPressed, isNull);
      await tearDownHarness(tester, h);
    });
  });

  group('admins screen', () {
    Future<(ChannelHarness, ContactsController)> pumpAdmins(
      WidgetTester tester,
      void Function(ChannelHarness h) setup,
    ) async {
      final h = await harness(tester, channelInfo(role: 'owner'), setup: setup);
      final contacts = ContactsController(database: h.db);
      await pump(
        tester,
        h,
        const ChannelAdminsScreen(channelId: 'c1'),
        extra: [ChangeNotifierProvider.value(value: contacts)],
      );
      return (h, contacts);
    }

    testWidgets('shows role, handle and BOT badge from the server; changes '
        'a role', (tester) async {
      final (h, contacts) = await pumpAdmins(
        tester,
        (h) => h.api.admins = [
          ChannelAdminDto.fromJson({
            'deviceId': 'b1',
            'addedAt': '2026-11-05T10:00:00Z',
            'role': 'publisher',
            'isBot': true,
            'handle': 'CT-BOT0-0001',
            'displayName': 'Newsletter',
          }),
        ],
      );
      expect(find.text('Newsletter'), findsOneWidget);
      expect(find.text('BOT'), findsOneWidget);
      expect(find.text('CT-BOT0-0001 · publisher'), findsOneWidget);

      await tester.tap(find.byTooltip(l10nEn.channelAdminsChangeRole));
      await settle(tester);
      await tester.tap(find.text(l10nEn.channelAdminsRoleAdminHelp));
      await settle(tester);
      expect(h.api.calls, contains('admin b1 true admin'));
      expect(find.text(l10nEn.channelAdminsRoleChanged), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      contacts.dispose();
      await tearDownHarness(tester, h);
    });

    testWidgets('add by handle: a bot defaults to publisher', (tester) async {
      final (h, contacts) = await pumpAdmins(
        tester,
        (h) => h.api.devicesByHandle['CT-BOT0-0002'] = {
          'deviceId': 'b2',
          'userHandle': 'CT-BOT0-0002',
          'isBot': true,
          'displayName': 'Digest',
        },
      );
      await tester.tap(find.byKey(const Key('admin-add-by-handle')));
      await settle(tester);
      await tester.enterText(
        find.byKey(const Key('admin-handle-field')),
        'ct-bot0-0002',
      );
      await tester.tap(find.text(l10nEn.commonOpen));
      await settle(tester);
      expect(find.text(l10nEn.channelAdminsAddTitle('Digest')), findsOneWidget);
      expect(find.text('BOT'), findsOneWidget);
      await tester.tap(find.text(l10nEn.channelAdminsAdd));
      await settle(tester);
      expect(h.api.calls, contains('by-handle CT-BOT0-0002'));
      expect(h.api.calls, contains('admin b2 true publisher'));

      await tester.pumpWidget(const SizedBox());
      contacts.dispose();
      await tearDownHarness(tester, h);
    });

    testWidgets('add by handle: unknown handle', (tester) async {
      final (h, contacts) = await pumpAdmins(tester, (_) {});
      await tester.tap(find.byKey(const Key('admin-add-by-handle')));
      await settle(tester);
      await tester.enterText(
        find.byKey(const Key('admin-handle-field')),
        'CT-NONE-0000',
      );
      await tester.tap(find.text(l10nEn.commonOpen));
      await settle(tester);
      expect(find.text(l10nEn.channelAdminsHandleNotFound), findsOneWidget);
      expect(h.api.calls.where((c) => c.startsWith('admin ')), isEmpty);

      await tester.pumpWidget(const SizedBox());
      contacts.dispose();
      await tearDownHarness(tester, h);
    });
  });

  testWidgets('create screen states that creating accepts the rules', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({'ct_account_id': 'acc-1'});
    final h = ChannelHarness();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider.value(value: SecureStorage()),
          ChangeNotifierProvider<ChannelsController>.value(value: h.controller),
        ],
        child: localizedApp(home: const ChannelCreateScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(l10nEn.channelCreateRulesAgree), findsOneWidget);
    await tester.tap(find.text(l10nEn.channelRules));
    await tester.pumpAndSettle();
    expect(launched.single.host, 'jay.zcloud.cz');
    await tearDownHarness(tester, h);
  });

  group('controller', () {
    test('sync skips the feed of a suspended channel a follower cannot '
        'read, and stores the status', () async {
      final h = ChannelHarness();
      addTearDown(h.dispose);
      h.api.suspendedFeeds.add('c1');
      h.api.mine = [
        ChannelInfo(
          channelId: 'c1',
          handle: 'CH-NEWS-0001',
          name: 'News',
          unreadCount: 3,
          status: 'suspended',
          suspendedUntil: DateTime.now().toUtc().add(const Duration(days: 1)),
        ),
      ];
      await h.controller.sync(); // would throw if it fetched posts
      final channel = h.controller.channel('c1')!;
      expect(channel.status, 'suspended');
      expect(channelIsSuspended(channel), isTrue);
      expect(h.api.calls.where((c) => c.startsWith('posts')), isEmpty);

      // Restored: the next sync clears it.
      h.api.suspendedFeeds.clear();
      h.api.mine = [
        const ChannelInfo(
          channelId: 'c1',
          handle: 'CH-NEWS-0001',
          name: 'News',
        ),
      ];
      await h.controller.sync();
      expect(channelIsSuspended(h.controller.channel('c1')!), isFalse);
    });

    test('byBot is stored from the hub event', () async {
      final h = ChannelHarness();
      addTearDown(h.dispose);
      h.api.mine = [news];
      await h.controller.sync();
      await h.emitPost(postEvent('p1', byBot: true));
      final post = await h.db.select(h.db.channelPosts).getSingle();
      expect(post.byBot, isTrue);
      expect(post.publishedHere, isFalse);
    });

    test('channelErrorMessage words the moderation codes', () {
      DioException failure(int status, String code) {
        final options = RequestOptions(path: '/x');
        return DioException(
          requestOptions: options,
          response: Response(
            requestOptions: options,
            statusCode: status,
            data: {'error': 'x', 'code': code},
          ),
        );
      }

      expect(
        channelErrorMessage(l10nEn, failure(403, 'channel_suspended')),
        l10nEn.channelErrorSuspended,
      );
      expect(
        channelErrorMessage(l10nEn, failure(429, 'bot_post_limit')),
        l10nEn.channelErrorBotPostLimit,
      );
      expect(
        channelErrorMessage(l10nEn, failure(400, 'good_faith_required')),
        l10nEn.channelErrorGoodFaithRequired,
      );
      expect(
        channelErrorMessage(l10nEn, failure(400, 'invalid_contact')),
        l10nEn.channelReportEmailInvalid,
      );
    });

    test('rules link: Czech UI gets the Czech page', () {
      expect(
        channelRulesUrl(
          lookupAppLocalizations(const Locale('cs')).localeName,
          rule: 'K1',
        ),
        'https://jay.zcloud.cz/legal/channels-cs.html#K1',
      );
    });
  });
}
