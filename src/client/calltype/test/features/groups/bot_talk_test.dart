import 'dart:async';

import 'package:calltype_core/network/api_client.dart';
import 'package:calltype/features/groups/bot_talk_controller.dart';
import 'package:calltype/features/groups/bot_talk_screen.dart';
import 'package:calltype/shared/widgets/bot_badge.dart';
import 'package:calltype_core/network/group_dtos.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../helpers/localized_app.dart';

const _group = 'group-1';
const _me = 'ME-DEVICE';
const _botA = 'bot-a';
const _botB = 'bot-b';
const _auditor = 'auditor-1';

/// Fake of the group endpoints the setting uses (subclassing, like the other
/// feature tests). [saveError] simulates a server refusal.
class FakeBotTalkApi extends ApiClient {
  FakeBotTalkApi({this.myRole = 'admin', this.botTalk = BotTalkSettings.off})
    : super(baseUrl: 'http://unused');

  String myRole;
  BotTalkSettings botTalk;
  int reads = 0;
  final saves = <Map<String, dynamic>>[];
  DioException? saveError;

  @override
  Future<GroupDetails> getGroup(String groupId) async {
    reads++;
    return GroupDetails(groupId: groupId, botTalk: botTalk);
  }

  @override
  Future<List<GroupMemberInfo>> getGroupMemberInfos(String groupId) async => [
    // Lower case here, upper case in selfDeviceId: the match ignores case.
    GroupMemberInfo(deviceId: _me.toLowerCase(), role: myRole),
    const GroupMemberInfo(deviceId: 'human-2', displayName: 'Alice'),
    const GroupMemberInfo(
      deviceId: _botA,
      displayName: 'Hermes Dev',
      userHandle: 'CT-DEV0-0001',
      isBot: true,
    ),
    const GroupMemberInfo(
      deviceId: _botB,
      displayName: 'Hermes Ops',
      isBot: true,
    ),
    // A business auditor is never a bot-talk participant.
    const GroupMemberInfo(
      deviceId: _auditor,
      displayName: 'Archiver',
      isBot: true,
      role: 'auditor',
    ),
  ];

  @override
  Future<BotTalkSettings> setGroupBotTalk(
    String groupId,
    BotTalkSettings settings,
  ) async {
    if (saveError != null) throw saveError!;
    saves.add(settings.toJson());
    botTalk = settings;
    return settings;
  }
}

DioException problem(int status, [String? code]) {
  final options = RequestOptions(path: '/groups/$_group/bot-talk');
  return DioException(
    requestOptions: options,
    response: Response(
      requestOptions: options,
      statusCode: status,
      data: code == null ? null : {'title': 'Bad', 'error': code},
    ),
  );
}

void main() {
  group('BotTalkController', () {
    test(
      'admin row of THIS device enables editing; bots exclude auditor',
      () async {
        final c = BotTalkController(
          apiClient: FakeBotTalkApi(),
          groupId: _group,
          selfDeviceId: _me,
        );
        addTearDown(c.dispose);
        await c.load();
        expect(c.canEdit, isTrue);
        expect(c.bots.map((b) => b.deviceId), [_botA, _botB]);
      },
    );

    test('a member (or a companion, which has no row) is read-only', () async {
      final member = BotTalkController(
        apiClient: FakeBotTalkApi(myRole: 'member'),
        groupId: _group,
        selfDeviceId: _me,
      );
      final companion = BotTalkController(
        apiClient: FakeBotTalkApi(),
        groupId: _group,
        selfDeviceId: 'companion-device',
      );
      addTearDown(member.dispose);
      addTearDown(companion.dispose);
      await member.load();
      await companion.load();
      expect(member.canEdit, isFalse);
      expect(companion.canEdit, isFalse);
      // Read-only means the draft cannot be changed either.
      member.setMode(BotTalkMode.all);
      expect(member.mode, BotTalkMode.off);
    });

    test('range validation', () {
      expect(BotTalkController.parseInRange('0', 1, 50), isNull);
      expect(BotTalkController.parseInRange('1', 1, 50), 1);
      expect(BotTalkController.parseInRange(' 50 ', 1, 50), 50);
      expect(BotTalkController.parseInRange('51', 1, 50), isNull);
      expect(BotTalkController.parseInRange('', 0, 1440), isNull);
      expect(BotTalkController.parseInRange('1440', 0, 1440), 1440);
      expect(BotTalkController.parseInRange('1441', 0, 1440), isNull);
      expect(BotTalkController.parseInRange('2.5', 0, 1440), isNull);
    });

    test('invalid numbers never reach the server', () async {
      final api = FakeBotTalkApi();
      final c = BotTalkController(
        apiClient: api,
        groupId: _group,
        selfDeviceId: _me,
      );
      addTearDown(c.dispose);
      await c.load();
      c.setMaxTurnsText('99');
      expect(await c.save(), BotTalkError.invalid);
      expect(api.saves, isEmpty);
    });

    test('selected mode sends only the checked bots', () async {
      final api = FakeBotTalkApi();
      final c = BotTalkController(
        apiClient: api,
        groupId: _group,
        selfDeviceId: _me,
      );
      addTearDown(c.dispose);
      await c.load();
      c
        ..setMode(BotTalkMode.selected)
        ..toggleBot(_botA, true)
        ..setMaxTurnsText('10')
        ..setPauseText('0');
      expect(await c.save(), isNull);
      expect(api.saves.single, {
        'mode': 'selected',
        'allowedBotDeviceIds': [_botA],
        'maxBotTurns': 10,
        'pauseMinutes': 0,
        // Group topics T3/T4: always sent, kept from the server value.
        'botsReadAll': false,
        'replyWithoutMention': false,
      });
    });

    test('server errors map to codes; 403 makes the form read-only', () async {
      final api = FakeBotTalkApi();
      final c = BotTalkController(
        apiClient: api,
        groupId: _group,
        selfDeviceId: _me,
      );
      addTearDown(c.dispose);
      await c.load();

      api.saveError = problem(400, 'not_a_bot_member');
      expect(await c.save(), BotTalkError.notABotMember);
      api.saveError = problem(400, 'invalid_mode');
      expect(await c.save(), BotTalkError.invalid);
      api.saveError = problem(500);
      expect(await c.save(), BotTalkError.failed);
      expect(c.canEdit, isTrue);
      api.saveError = problem(403);
      expect(await c.save(), BotTalkError.forbidden);
      expect(c.canEdit, isFalse);
    });

    test('a GroupChanged hint for this group re-reads it', () async {
      final api = FakeBotTalkApi();
      final hints = StreamController<Map<String, dynamic>>.broadcast();
      final c = BotTalkController(
        apiClient: api,
        groupId: _group,
        selfDeviceId: _me,
        groupChanged: hints.stream,
      );
      addTearDown(() async {
        c.dispose();
        await hints.close();
      });
      await c.load();
      expect(api.reads, 1);

      hints.add({'groupId': 'other-group'});
      await Future<void>.delayed(Duration.zero);
      expect(api.reads, 1);

      api.botTalk = const BotTalkSettings(mode: BotTalkMode.all);
      hints.add({'groupId': _group});
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(api.reads, 2);
      expect(c.mode, BotTalkMode.all);
    });
  });

  group('BotTalkScreen', () {
    Future<FakeBotTalkApi> pumpScreen(
      WidgetTester tester, {
      String myRole = 'admin',
      BotTalkSettings botTalk = BotTalkSettings.off,
    }) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final api = FakeBotTalkApi(myRole: myRole, botTalk: botTalk);
      await tester.pumpWidget(
        ChangeNotifierProvider(
          create: (_) => BotTalkController(
            apiClient: api,
            groupId: _group,
            selfDeviceId: _me,
          ),
          child: localizedApp(home: const BotTalkScreen()),
        ),
      );
      await tester.pumpAndSettle();
      return api;
    }

    testWidgets('admin sees the bot checklist with BOT badges and can save', (
      tester,
    ) async {
      final api = await pumpScreen(tester);
      expect(find.text('Hermes Dev'), findsOneWidget);
      expect(find.text('Hermes Ops'), findsOneWidget);
      expect(find.text('Archiver'), findsNothing);
      expect(find.byType(BotBadge), findsNWidgets(2));
      expect(find.text(l10nEn.botTalkReadOnly), findsNothing);

      await tester.tap(find.text(l10nEn.botTalkModeSelected));
      await tester.pump();
      await tester.tap(find.text('Hermes Ops'));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('bot-talk-max-turns')),
        '12',
      );
      await tester.tap(find.text(l10nEn.commonSave));
      await tester.pumpAndSettle();

      expect(api.saves.single['mode'], 'selected');
      expect(api.saves.single['allowedBotDeviceIds'], [_botB]);
      expect(api.saves.single['maxBotTurns'], 12);
      expect(find.text(l10nEn.botTalkSaved), findsOneWidget);
    });

    testWidgets('T3/T4 switches show the server value and are saved', (
      tester,
    ) async {
      // Spec 2026-11-13-group-topics row 15: independent of the mode, and
      // a save of the mode keeps the other flag as the server had it.
      final api = await pumpScreen(
        tester,
        botTalk: const BotTalkSettings(replyWithoutMention: true),
      );
      SwitchListTile tile(String key) =>
          tester.widget<SwitchListTile>(find.byKey(ValueKey(key)));
      expect(find.text(l10nEn.botTalkReadAllTitle), findsOneWidget);
      expect(find.text(l10nEn.botTalkReadAllHint), findsOneWidget);
      expect(find.text(l10nEn.botTalkReplyWithoutMentionHint), findsOneWidget);
      expect(tile('bot-talk-read-all').value, isFalse);
      expect(tile('bot-talk-reply-without-mention').value, isTrue);

      await tester.tap(find.byKey(const ValueKey('bot-talk-read-all')));
      await tester.pump();
      expect(tile('bot-talk-read-all').value, isTrue);
      await tester.tap(find.text(l10nEn.commonSave));
      await tester.pumpAndSettle();

      expect(api.saves.single['botsReadAll'], isTrue);
      expect(api.saves.single['replyWithoutMention'], isTrue);
      expect(api.saves.single['mode'], 'off');
    });

    testWidgets('non-admin cannot flip the T3/T4 switches', (tester) async {
      await pumpScreen(tester, myRole: 'member');
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('bot-talk-read-all')),
            )
            .onChanged,
        isNull,
      );
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('bot-talk-reply-without-mention')),
            )
            .onChanged,
        isNull,
      );
    });

    testWidgets('an out-of-range number shows an error and disables Save', (
      tester,
    ) async {
      final api = await pumpScreen(tester);
      await tester.enterText(
        find.byKey(const ValueKey('bot-talk-pause')),
        '2000',
      );
      await tester.pump();
      expect(find.text(l10nEn.botTalkPauseInvalid), findsOneWidget);
      final save = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(save.onPressed, isNull);
      expect(api.saves, isEmpty);
    });

    testWidgets('non-admin sees the setting read-only, without Save', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        myRole: 'member',
        botTalk: const BotTalkSettings(
          mode: BotTalkMode.selected,
          allowedBotDeviceIds: [_botA],
          maxBotTurns: 7,
        ),
      );
      expect(find.text(l10nEn.botTalkReadOnly), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('bot-talk-max-turns')),
      );
      expect(field.enabled, isFalse);
      expect(field.controller!.text, '7');
      final checkbox = tester.widget<CheckboxListTile>(
        find.byKey(const ValueKey('bot-$_botA')),
      );
      expect(checkbox.value, isTrue);
      expect(checkbox.onChanged, isNull);
    });

    testWidgets('a server refusal is shown as a localized message', (
      tester,
    ) async {
      final api = await pumpScreen(tester);
      api.saveError = problem(400, 'not_a_bot_member');
      await tester.tap(find.text(l10nEn.commonSave));
      await tester.pumpAndSettle();
      expect(find.text(l10nEn.botTalkErrorNotABot), findsOneWidget);
    });
  });
}
