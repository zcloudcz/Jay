import 'package:calltype/core/network/api_client.dart';
import 'package:calltype/core/storage/database.dart';
import 'package:calltype/features/chat_list/chat_list_controller.dart';
import 'package:calltype/features/channels/channels_controller.dart';
import 'package:calltype/features/mute/mute_controller.dart';
import 'package:calltype/features/mute/mute_dialog.dart';
import 'package:calltype/shared/widgets/main_navigation_bar.dart';
import 'package:calltype_core/network/group_dtos.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../helpers/localized_app.dart';
import '../channels/fake_channels.dart';

/// Records the mute endpoints (same subclassing style as the other fakes).
class FakeMuteApi extends ApiClient {
  FakeMuteApi() : super(baseUrl: 'http://unused');

  List<MuteEntry> mutes = [];
  final calls = <String>[];
  final sent = <MuteSetting>[];
  bool fail = false;

  @override
  Future<List<MuteEntry>> getMutes() async {
    calls.add('getMutes');
    return mutes;
  }

  @override
  Future<void> setGroupMute(String groupId, MuteSetting mute) async {
    if (fail) throw StateError('offline');
    calls.add('group $groupId ${mute.mode.name}');
    sent.add(mute);
  }

  @override
  Future<void> setDirectMute(String peerDeviceId, MuteSetting mute) async {
    if (fail) throw StateError('offline');
    calls.add('direct $peerDeviceId ${mute.mode.name}');
    sent.add(mute);
  }
}

/// A chat list with fixed rows: the badge logic only reads `conversations`.
class StaticChats extends ChatListController {
  StaticChats(this.rows, AppDatabase db) : super(database: db);
  final List<Conversation> rows;
  @override
  List<Conversation> get conversations => rows;
}

Conversation conv(String id, int unread, {String type = 'direct'}) =>
    Conversation(id: id, type: type, unreadCount: unread);

final now = DateTime.utc(2026, 11, 5, 12);

void main() {
  group('MuteController', () {
    test('loads GET /mutes keyed case-insensitively; expired = off', () async {
      final api = FakeMuteApi()
        ..mutes = [
          const MuteEntry(
            groupId: 'G-1',
            setting: MuteSetting(mode: MuteMode.all),
          ),
          MuteEntry(
            peerDeviceId: 'peer-a',
            setting: MuteSetting(
              mode: MuteMode.bots,
              until: now.add(const Duration(hours: 1)),
            ),
          ),
          MuteEntry(
            peerDeviceId: 'peer-old',
            setting: MuteSetting(
              mode: MuteMode.all,
              until: now.subtract(const Duration(minutes: 1)),
            ),
          ),
        ];
      final mutes = MuteController(apiClient: api, clock: () => now);
      addTearDown(mutes.dispose);
      await mutes.load();

      expect(mutes.modeOf('g-1'), MuteMode.all);
      expect(mutes.modeOf('PEER-A'), MuteMode.bots);
      expect(mutes.modeOf('peer-old'), MuteMode.off);
      expect(mutes.isMuted('unknown'), isFalse);
    });

    test('group mute calls setGroupMute, 1:1 calls setDirectMute', () async {
      final api = FakeMuteApi();
      final mutes = MuteController(apiClient: api, clock: () => now);
      addTearDown(mutes.dispose);

      await mutes.setMute(
        conversationId: 'g1',
        group: true,
        setting: const MuteSetting(mode: MuteMode.bots),
      );
      await mutes.setMute(
        conversationId: 'peer',
        group: false,
        setting: const MuteSetting(mode: MuteMode.all),
      );
      expect(api.calls, ['group g1 bots', 'direct peer all']);
      expect(mutes.modeOf('g1'), MuteMode.bots);
      expect(mutes.modeOf('peer'), MuteMode.all);

      await mutes.setMute(
        conversationId: 'peer',
        group: false,
        setting: MuteSetting.off,
      );
      expect(mutes.isMuted('peer'), isFalse);
    });

    test('a failed PUT leaves the cache untouched', () async {
      final api = FakeMuteApi()..fail = true;
      final mutes = MuteController(apiClient: api, clock: () => now);
      addTearDown(mutes.dispose);
      await expectLater(
        mutes.setMute(
          conversationId: 'g1',
          group: true,
          setting: const MuteSetting(mode: MuteMode.all),
        ),
        throwsStateError,
      );
      expect(mutes.isMuted('g1'), isFalse);
    });

    test('muted conversations do not count into the unread total', () async {
      final mutes = MuteController(apiClient: FakeMuteApi(), clock: () => now);
      addTearDown(mutes.dispose);
      mutes.applyGroupMute('g1', const MuteSetting(mode: MuteMode.all));
      mutes.applyGroupMute('g2', const MuteSetting(mode: MuteMode.bots));
      mutes.applyGroupMute(
        'g3',
        MuteSetting(mode: MuteMode.all, until: now), // expired right now
      );
      final rows = [
        conv('g1', 5, type: 'group'),
        conv('g2', 7, type: 'group'),
        conv('g3', 2, type: 'group'),
        conv('peer', 1),
      ];
      expect(mutes.unreadTotal(rows), 3);
    });

    test('MuteDuration builds the wire value', () {
      expect(
        MuteDuration.oneHour.settingFor(MuteMode.all, now).until,
        now.add(const Duration(hours: 1)),
      );
      expect(MuteDuration.forever.settingFor(MuteMode.all, now).until, isNull);
      // "Off" never carries an until.
      expect(MuteDuration.oneWeek.settingFor(MuteMode.off, now).until, isNull);
    });
  });

  group('MuteButton', () {
    Future<(FakeMuteApi, MuteController)> pumpButton(
      WidgetTester tester, {
      required bool group,
    }) async {
      // Tall surface: the dialog with all duration options must fit.
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final api = FakeMuteApi();
      final mutes = MuteController(apiClient: api);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: mutes,
          child: localizedApp(
            home: Scaffold(
              appBar: AppBar(
                actions: [MuteButton(conversationId: 'conv-1', group: group)],
              ),
            ),
          ),
        ),
      );
      return (api, mutes);
    }

    // Explicit, not addTearDown: the mute's expiry timer must be cancelled
    // before the test binding checks for pending timers.
    Future<void> disposeButton(
      WidgetTester tester,
      MuteController mutes,
    ) async {
      await tester.pumpWidget(const SizedBox());
      mutes.dispose();
    }

    testWidgets('1:1: "Bots only" for 1 week calls setDirectMute', (
      tester,
    ) async {
      final (api, mutes) = await pumpButton(tester, group: false);
      expect(find.byIcon(Icons.notifications_none_rounded), findsOneWidget);

      await tester.tap(find.byTooltip(l10nEn.muteTitle));
      await tester.pumpAndSettle();
      // The duration only appears once a mute mode is picked.
      expect(find.text(l10nEn.muteDurationWeek), findsNothing);
      await tester.tap(find.text(l10nEn.muteModeBots));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10nEn.muteDurationWeek));
      await tester.tap(find.text(l10nEn.commonSave));
      await tester.pumpAndSettle();

      expect(api.calls, ['direct conv-1 bots']);
      final until = api.sent.single.until!;
      final week = until.difference(DateTime.now().toUtc());
      expect(week.inHours, inInclusiveRange(167, 168));
      expect(find.byIcon(Icons.notifications_paused_outlined), findsOneWidget);
      await disposeButton(tester, mutes);
    });

    testWidgets('group: "All messages" forever calls setGroupMute', (
      tester,
    ) async {
      final (api, mutes) = await pumpButton(tester, group: true);
      await tester.tap(find.byTooltip(l10nEn.muteTitle));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10nEn.muteModeAll));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10nEn.muteDurationForever));
      await tester.tap(find.text(l10nEn.commonSave));
      await tester.pumpAndSettle();

      expect(api.calls, ['group conv-1 all']);
      expect(api.sent.single.until, isNull);
      expect(find.byIcon(Icons.notifications_off_outlined), findsOneWidget);
      await disposeButton(tester, mutes);
    });

    testWidgets('a failed save shows an error and keeps the icon', (
      tester,
    ) async {
      final (api, mutes) = await pumpButton(tester, group: true);
      api.fail = true;
      await tester.tap(find.byTooltip(l10nEn.muteTitle));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10nEn.muteModeAll));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10nEn.commonSave));
      await tester.pumpAndSettle();

      expect(find.text(l10nEn.muteFailed), findsOneWidget);
      expect(find.byIcon(Icons.notifications_none_rounded), findsOneWidget);
      await disposeButton(tester, mutes);
    });

    testWidgets('cancel calls nothing', (tester) async {
      final (api, mutes) = await pumpButton(tester, group: false);
      await tester.tap(find.byTooltip(l10nEn.muteTitle));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10nEn.commonCancel));
      await tester.pumpAndSettle();
      expect(api.calls, isEmpty);
      await disposeButton(tester, mutes);
    });
  });

  testWidgets('the Chats badge leaves muted conversations out', (tester) async {
    final h = (await tester.runAsync(() async => ChannelHarness()))!;
    // The harness's database: StaticChats never queries it, and a second
    // in-memory AppDatabase would only trigger drift's multi-instance warning.
    final chats = StaticChats([
      conv('muted-group', 9, type: 'group'),
      conv('peer', 2),
    ], h.db);
    final mutes = MuteController(apiClient: FakeMuteApi());
    mutes.applyGroupMute('muted-group', const MuteSetting(mode: MuteMode.all));

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ChannelsController>.value(value: h.controller),
          ChangeNotifierProvider<ChatListController>.value(value: chats),
          ChangeNotifierProvider.value(value: mutes),
        ],
        child: localizedApp(
          home: const Scaffold(
            bottomNavigationBar: MainNavigationBar(current: MainTab.chats),
          ),
        ),
      ),
    );
    expect(find.text('2'), findsOneWidget);
    expect(find.text('11'), findsNothing);

    // Unmuting brings the group's messages back into the badge.
    mutes.applyGroupMute('muted-group', MuteSetting.off);
    await tester.pump();
    expect(find.text('11'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    mutes.dispose();
    chats.dispose();
    await tester.runAsync(h.dispose);
  });
}
