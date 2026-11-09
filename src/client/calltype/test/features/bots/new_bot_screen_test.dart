import 'dart:io';

import 'package:calltype/features/bots/new_bot_command.dart';
import 'package:calltype/features/bots/new_bot_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/localized_app.dart';

const _api = 'https://api.example.invalid';
const _owner = 'CT-AAAA-0001';

/// What bash makes of the arguments after `bash -s --`: the script sees
/// exactly these words. Proves the quoting with a real shell.
List<String> _bashWords(String command) {
  const marker = '| bash -s -- ';
  final args = command.substring(command.indexOf(marker) + marker.length);
  final result = Process.runSync('bash', ['-c', "printf '%s\\n' $args"]);
  expect(result.exitCode, 0, reason: '${result.stderr}');
  final out = result.stdout as String;
  return out.substring(0, out.length - 1).split('\n');
}

bool _hasBash() {
  try {
    return Process.runSync('bash', ['-c', 'true']).exitCode == 0;
  } catch (_) {
    return false;
  }
}

void main() {
  group('newBotCommand', () {
    test('Linux: one curl | bash line with every value', () {
      expect(
        newBotCommand(
          name: 'Pepa',
          ownerHandle: 'ct-aaaa-0001',
          apiBaseUrl: '$_api/',
          provider: BotProvider.anthropic,
          target: BotTarget.linux,
        ),
        "curl -fsSL https://jay.zcloud.cz/bots/new-bot.sh | bash -s -- "
        "--name 'Pepa' --owner 'CT-AAAA-0001' --provider anthropic "
        "--api 'https://api.example.invalid'",
      );
    });

    test('macOS is the same script; Docker adds --docker', () {
      String cmd(BotTarget t) => newBotCommand(
        name: 'Pepa',
        ownerHandle: _owner,
        apiBaseUrl: _api,
        provider: BotProvider.openai,
        target: t,
      );
      expect(cmd(BotTarget.macos), cmd(BotTarget.linux));
      expect(cmd(BotTarget.docker), endsWith(" --api '$_api' --docker"));
    });

    test('Windows: PowerShell scriptblock with -Name/-Owner/-Provider/-Api', () {
      expect(
        newBotCommand(
          name: "Pepa's bot",
          ownerHandle: _owner,
          apiBaseUrl: _api,
          provider: BotProvider.claudeCli,
          target: BotTarget.windows,
        ),
        "& ([scriptblock]::Create((irm https://jay.zcloud.cz/bots/new-bot.ps1))) "
        "-Name 'Pepa''s bot' -Owner 'CT-AAAA-0001' -Provider claude-cli "
        "-Api 'https://api.example.invalid'",
      );
    });

    test(
      'names with spaces, quotes and shell syntax reach the script verbatim',
      () {
        for (final name in [
          'Můj bot',
          "Pepa's \"test\" bot",
          r'$(rm -rf ~) `id` $HOME',
          "it's; echo pwned & | > x",
        ]) {
          final command = newBotCommand(
            name: name,
            ownerHandle: _owner,
            apiBaseUrl: _api,
            provider: BotProvider.hermes,
            target: BotTarget.linux,
          );
          expect(_bashWords(command), [
            '--name',
            name,
            '--owner',
            _owner,
            '--provider',
            'hermes',
            '--api',
            _api,
          ]);
        }
      },
      skip: _hasBash() ? false : 'bash is not installed',
    );

    test('PowerShell quoting doubles single quotes and keeps \$ literal', () {
      expect(powerShellQuote(r"a'b $(x) $y"), r"'a''b $(x) $y'");
      expect(shellQuote("a'b"), r"'a'\''b'");
    });

    test('no command carries anything key-like', () {
      for (final p in BotProvider.values) {
        for (final t in BotTarget.values) {
          final c = newBotCommand(
            name: 'x',
            ownerHandle: _owner,
            apiBaseUrl: _api,
            provider: p,
            target: t,
          );
          expect(c.toLowerCase(), isNot(contains('key')));
          expect(c, isNot(contains('sk-')));
        }
      }
    });

    test('name validation matches the scripts', () {
      expect(isValidBotName('Pepa'), isTrue);
      expect(isValidBotName('Žluťoučký kůň'), isTrue);
      expect(isValidBotName('Bot 1'), isTrue);
      expect(isValidBotName(''), isFalse);
      expect(isValidBotName('   '), isFalse);
      expect(isValidBotName('!!!'), isFalse);
      expect(isValidBotName('机器人'), isFalse);
      expect(isValidBotName('a' * 41), isFalse);
      expect(isValidBotName('a\nb'), isFalse);
    });

    test('default target follows the platform; phones get Linux', () {
      expect(defaultBotTarget(TargetPlatform.windows), BotTarget.windows);
      expect(defaultBotTarget(TargetPlatform.macOS), BotTarget.macos);
      expect(defaultBotTarget(TargetPlatform.linux), BotTarget.linux);
      expect(defaultBotTarget(TargetPlatform.android), BotTarget.linux);
      expect(defaultBotTarget(TargetPlatform.iOS), BotTarget.linux);
    });
  });

  group('NewBotScreen', () {
    late List<String> clipboard;

    setUp(() {
      clipboard = [];
      TestWidgetsFlutterBinding.ensureInitialized();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard.add((call.arguments as Map)['text'] as String);
            }
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    Future<void> pump(
      WidgetTester tester, {
      String? owner = _owner,
      TargetPlatform platform = TargetPlatform.linux,
    }) async {
      // A tall surface: the wizard is a lazy ListView, and a phone-sized
      // test view would leave the button below the fold, unbuilt.
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        localizedApp(
          home: NewBotScreen(
            ownerHandleLoader: (_) async => owner,
            apiBaseUrl: _api,
            platform: platform,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<String> showCommand(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('new-bot-show-command')));
      await tester.pumpAndSettle();
      return tester
          .widget<SelectableText>(find.byKey(const ValueKey('new-bot-command')))
          .data!;
    }

    testWidgets('form has the name as its ONLY text field (no key field)', (
      tester,
    ) async {
      await pump(tester);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byKey(const ValueKey('new-bot-name')), findsOneWidget);
      for (final p in BotProvider.values) {
        expect(
          find.byKey(ValueKey('new-bot-provider-${p.id}')),
          findsOneWidget,
        );
      }
    });

    testWidgets('show command is disabled until the name is valid', (
      tester,
    ) async {
      await pump(tester);
      FilledButton button() => tester.widget<FilledButton>(
        find.byKey(const ValueKey('new-bot-show-command')),
      );
      expect(button().onPressed, isNull);
      await tester.enterText(find.byKey(const ValueKey('new-bot-name')), '!!!');
      await tester.pump();
      expect(find.text(l10nEn.newBotNameInvalid), findsOneWidget);
      expect(button().onPressed, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('new-bot-name')),
        'Pepa',
      );
      await tester.pump();
      expect(button().onPressed, isNotNull);
    });

    testWidgets('Linux + Claude API: command with name, owner, api, provider', (
      tester,
    ) async {
      await pump(tester);
      await tester.enterText(
        find.byKey(const ValueKey('new-bot-name')),
        "Pepa's bot",
      );
      await tester.pump();
      final command = await showCommand(tester);
      expect(
        command,
        newBotCommand(
          name: "Pepa's bot",
          ownerHandle: _owner,
          apiBaseUrl: _api,
          provider: BotProvider.anthropic,
          target: BotTarget.linux,
        ),
      );
      expect(command, contains("--name 'Pepa'\\''s bot'"));
      expect(find.byType(TextField), findsNothing);
      expect(find.text(l10nEn.newBotStepTerminal), findsOneWidget);
      expect(find.text(l10nEn.newBotStepKey), findsOneWidget);
      expect(find.text(l10nEn.newBotStepWait), findsOneWidget);
      expect(find.byKey(const ValueKey('new-bot-note')), findsNothing);
      // Who can reach it, and that members' questions cost the owner's key.
      expect(find.text(l10nEn.newBotAccessApi), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('new-bot-copy')));
      await tester.pumpAndSettle();
      expect(clipboard, [command]);
      expect(find.text(l10nEn.newBotCopied), findsOneWidget);
    });

    testWidgets('Windows is preselected on Windows and gives PowerShell', (
      tester,
    ) async {
      await pump(tester, platform: TargetPlatform.windows);
      await tester.enterText(
        find.byKey(const ValueKey('new-bot-name')),
        'Pepa',
      );
      await tester.tap(
        find.byKey(const ValueKey('new-bot-provider-claude-cli')),
      );
      await tester.pump();
      final command = await showCommand(tester);
      expect(command, startsWith('& ([scriptblock]::Create('));
      expect(command, contains('-Provider claude-cli'));
      expect(find.text(l10nEn.newBotStepPowerShell), findsOneWidget);
      // Subscription: what to install first, personal use, no key step.
      expect(find.text(l10nEn.newBotNoteClaudeCli), findsOneWidget);
      expect(find.text(l10nEn.newBotStepKey), findsNothing);
      expect(find.text(l10nEn.newBotUpdateHintWindows), findsOneWidget);
      // Subscription bots answer only the owner unless opted in, with the
      // PowerShell spelling of the option.
      expect(
        find.text(l10nEn.newBotAccessCli('-GroupReplies members')),
        findsOneWidget,
      );
    });

    testWidgets('Docker disables the subscription providers', (tester) async {
      await pump(tester);
      await tester.tap(
        find.byKey(const ValueKey('new-bot-provider-codex-cli')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('new-bot-target-docker')));
      await tester.pump();
      RadioListTile<BotProvider> tile(BotProvider p) =>
          tester.widget<RadioListTile<BotProvider>>(
            find.byKey(ValueKey('new-bot-provider-${p.id}')),
          );
      expect(tile(BotProvider.codexCli).enabled, isFalse);
      expect(tile(BotProvider.claudeCli).enabled, isFalse);
      expect(tile(BotProvider.hermes).enabled, isTrue);
      expect(find.text(l10nEn.newBotNoteDockerCli), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('new-bot-name')),
        'Pepa',
      );
      await tester.pump();
      final command = await showCommand(tester);
      // The subscription choice fell back to an API key provider.
      expect(command, contains('--provider anthropic'));
      expect(command, endsWith('--docker'));
    });

    testWidgets('back returns to the form with the values kept', (
      tester,
    ) async {
      await pump(tester);
      await tester.enterText(
        find.byKey(const ValueKey('new-bot-name')),
        'Pepa',
      );
      await tester.pump();
      await showCommand(tester);
      await tester.tap(find.text(l10nEn.newBotBack));
      await tester.pumpAndSettle();
      expect(find.text('Pepa'), findsOneWidget);
    });

    testWidgets('unknown own handle: explanation instead of a command', (
      tester,
    ) async {
      await pump(tester, owner: null);
      expect(find.text(l10nEn.newBotNoHandle), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('BotsScreen explains bots and opens the wizard', (
      tester,
    ) async {
      var opened = 0;
      await tester.pumpWidget(
        localizedApp(home: BotsScreen(onNewBot: () => opened++)),
      );
      expect(find.text(l10nEn.botsIntro), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('bots-new-bot')));
      expect(opened, 1);
    });
  });
}
