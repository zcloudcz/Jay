import 'package:llm_bridge/llm_bridge.dart';
import 'package:test/test.dart';

/// The OS rules of process launching, checked for every OS on any host
/// (the real Windows path runs on the owner's machine, acceptance AC7).
void main() {
  group('planLaunch', () {
    test('Linux and macOS: direct, no shell, argv unchanged', () {
      for (final os in [HostOs.linux, HostOs.macos]) {
        final plan = planLaunch('/usr/bin/claude', [
          '-p',
          '--tools',
          '',
        ], os: os);
        expect(plan.executable, '/usr/bin/claude');
        expect(plan.arguments, ['-p', '--tools', '']);
        expect(plan.environment, isEmpty);
      }
    });

    test('Linux: even a file named .cmd starts directly', () {
      final plan = planLaunch('/opt/x/run.cmd', ['a'], os: HostOs.linux);
      expect(plan.executable, '/opt/x/run.cmd');
    });

    test('Windows .exe: direct, no shell', () {
      final plan = planLaunch(r'C:\Program Files\Claude\claude.exe', [
        '-p',
      ], os: HostOs.windows);
      expect(plan.executable, r'C:\Program Files\Claude\claude.exe');
      expect(plan.arguments, ['-p']);
      expect(plan.environment, isEmpty);
    });

    test('Windows .cmd/.bat: cmd.exe with the line in an env variable', () {
      final plan = planLaunch(
        r'C:\Users\Jan Novak\AppData\Roaming\npm\claude.CMD',
        ['-p', '--tools', '', r'C:\Users\Jan Novak\bot\system-prompt.txt'],
        os: HostOs.windows,
        comSpec: r'C:\Windows\system32\cmd.exe',
      );
      expect(plan.executable, r'C:\Windows\system32\cmd.exe');
      // No argument has a space or a quote: Dart passes them verbatim, and
      // the /c text does not start with a quote (cmd.exe strips nothing).
      expect(plan.arguments, ['/d', '/v:off', '/c', '%JAY_BRIDGE_CMDLINE%']);
      for (final a in plan.arguments) {
        expect(a, isNot(contains(' ')));
        expect(a, isNot(contains('"')));
      }
      expect(
        plan.environment[windowsCmdLineVariable],
        r'"C:\Users\Jan Novak\AppData\Roaming\npm\claude.CMD" "-p" "--tools" '
        r'"" "C:\Users\Jan Novak\bot\system-prompt.txt"',
      );
    });

    test('Windows batch: cmd metacharacters stay inside quotes', () {
      final plan = planLaunch(
        r'C:\bots\restart.bat',
        ['a & del x', 'x|y', '<in>', '100%', '^', 'semi;colon'],
        os: HostOs.windows,
        comSpec: 'cmd.exe',
      );
      expect(
        plan.environment[windowsCmdLineVariable],
        r'"C:\bots\restart.bat" "a & del x" "x|y" "<in>" "100%" "^" '
        r'"semi;colon"',
      );
    });
  });

  group('quoteForCmd', () {
    test('trailing backslashes are doubled before the closing quote', () {
      expect(quoteForCmd(r'C:\dir\'), r'"C:\dir\\"');
      expect(quoteForCmd(r'a\b'), r'"a\b"');
      expect(quoteForCmd(''), '""');
    });

    test('a double quote or a line break is refused', () {
      expect(() => quoteForCmd('say "hi"'), throwsArgumentError);
      expect(() => quoteForCmd('a\nb'), throwsArgumentError);
      expect(() => quoteForCmd('a\rb'), throwsArgumentError);
    });
  });

  group('treeKillCommands', () {
    test('Windows: taskkill the whole tree', () {
      expect(treeKillCommands(4242, HostOs.windows), [
        ['taskkill', '/PID', '4242', '/T', '/F'],
      ]);
    });

    test('Linux and macOS: nothing extra (signals)', () {
      expect(treeKillCommands(1, HostOs.linux), isEmpty);
      expect(treeKillCommands(1, HostOs.macos), isEmpty);
    });
  });

  test('normalizeNewlines: CRLF and CR become LF', () {
    expect(normalizeNewlines('a\r\nb\rc\n'), 'a\nb\nc\n');
  });

  test('processOutputDecoder survives non-UTF-8 console output', () {
    // "příkaz" in CP852, as cmd.exe prints it on a Czech Windows.
    final text = processOutputDecoder.convert([0x70, 0xFD, 0xA1, 0x6B]);
    expect(text, startsWith('p'));
    expect(text, endsWith('k'));
  });

  group('CLI providers on Windows (OS seam)', () {
    test('npm claude.cmd in a profile with a space: cmd.exe, argv intact', () {
      final p = ClaudeCliProvider(
        os: HostOs.windows,
        executable: r'C:\Users\Jan Novak\AppData\Roaming\npm\claude.cmd',
        workDir: r'C:\Users\Jan Novak\.jay-bots\x\data\bot.store.cli',
      );
      final args = p.arguments('sys');
      final plan = p.launchPlan(args);
      expect(plan.arguments, ['/d', '/v:off', '/c', '%JAY_BRIDGE_CMDLINE%']);
      final line = plan.environment[windowsCmdLineVariable]!;
      expect(line, startsWith(r'"C:\Users\Jan Novak\AppData\Roaming\npm'));
      expect(line, contains(r'"--tools" ""'));
      expect(
        line,
        contains(
          r'"C:\Users\Jan Novak\.jay-bots\x\data\bot.store.cli\'
          'system-prompt.txt"',
        ),
      );
    });

    test('native codex.exe: started directly with the same argv', () {
      final p = CodexCliProvider(
        os: HostOs.windows,
        executable: r'C:\Tools\codex.exe',
        workDir: r'C:\w',
      );
      final args = p.arguments('sys');
      final plan = p.launchPlan(args);
      expect(plan.executable, r'C:\Tools\codex.exe');
      expect(plan.arguments, args);
    });

    test(
      'exit 9009 (cmd.exe: not found, localized text) is a launch error',
      () {
        expect(CliProvider.isLaunchFailure(9009, 'není rozpoznán'), isTrue);
      },
    );
  });
}
