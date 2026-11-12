import 'dart:io';

import 'package:llm_bridge/llm_bridge.dart';
import 'package:test/test.dart';

void main() {
  group('splitCommandLine (A1 quoting rules)', () {
    test('spaces and tabs separate, runs of them count once', () {
      expect(splitCommandLine('  systemctl --user\tstatus  x '), [
        'systemctl',
        '--user',
        'status',
        'x',
      ]);
    });

    test('single quotes are literal, double quotes allow \\"', () {
      expect(splitCommandLine(r"""echo 'a "b" \c' "say \"hi\" \n" """), [
        'echo',
        r'a "b" \c',
        r'say "hi" \n',
      ]);
    });

    test('backslashes are plain (Windows paths), parts join, "" is empty', () {
      expect(
        splitCommandLine(r'C:\Tools\x.exe --dir="C:\Program Files\x" ""'),
        [r'C:\Tools\x.exe', r'--dir=C:\Program Files\x', ''],
      );
    });

    test('an unclosed quote is an error', () {
      expect(() => splitCommandLine('echo "oops'), throwsFormatException);
      expect(() => splitCommandLine("echo 'oops"), throwsFormatException);
    });
  });

  group('parseActions (A1)', () {
    test('unset or blank = none', () {
      expect(parseActions(null), isEmpty);
      expect(parseActions('  '), isEmpty);
    });

    test('the Linux example from the spec', () {
      final a = parseActions(
        'status=systemctl --user status hermes-gateway --no-pager; '
        'logs=journalctl --user -u hermes-gateway -n 200 --no-pager; '
        'restart=systemctl --user restart hermes-gateway; '
        'restart-bridge=systemctl --user restart jay-bridge',
      );
      expect(a.map((x) => x.name), [
        'status',
        'logs',
        'restart',
        'restart-bridge',
      ]);
      expect(a[2].argv, ['systemctl', '--user', 'restart', 'hermes-gateway']);
      expect(a[2].command, 'systemctl --user restart hermes-gateway');
    });

    test('a ; inside quotes does not split (PowerShell restart)', () {
      final a = parseActions(
        'restart=powershell -NoProfile -Command "Stop-ScheduledTask -TaskName '
        "'Hermes'; Start-ScheduledTask -TaskName 'Hermes'\"; status=schtasks "
        '/query /tn Hermes',
      );
      expect(a.map((x) => x.name), ['restart', 'status']);
      expect(a.first.argv, [
        'powershell',
        '-NoProfile',
        '-Command',
        "Stop-ScheduledTask -TaskName 'Hermes'; Start-ScheduledTask -TaskName "
            "'Hermes'",
      ]);
    });

    test('bad name, duplicate, empty command, quote, too many', () {
      Matcher err(String t) => throwsA(
        isA<ConfigException>().having((e) => e.message, 'm', contains(t)),
      );
      expect(() => parseActions('Restart=x'), err('action name "Restart"'));
      expect(() => parseActions('a b=x'), err('action name'));
      expect(() => parseActions('just-a-command'), err('is not name=command'));
      expect(() => parseActions('a=x; a=y'), err('"a" is listed twice'));
      expect(() => parseActions('a=  '), err('"a" has no command'));
      expect(() => parseActions('a=""'), err('"a" has no command'));
      expect(() => parseActions('a=echo "x'), err('unclosed'));
      expect(
        () => parseActions([for (var i = 0; i < 21; i++) 'a$i=x'].join(';')),
        err('at most 20'),
      );
      expect(
        parseActions([for (var i = 0; i < 20; i++) 'a$i=x'].join(';')),
        hasLength(20),
      );
    });

    test('LLM_ACTIONS through the config, with steps and seconds', () {
      final c = LlmConfig.fromEnvironment({
        'CALLTYPE_API_URL': 'https://api.example.invalid',
        'ALLOWED_HANDLES': 'CT-AAAA-0001',
        'LLM_PROVIDER': 'claude-cli',
        'LLM_ACTIONS': 'status=systemctl --user status x',
        'LLM_ACTION_STEPS': '2',
        'LLM_ACTION_SECONDS': '15',
      });
      expect(c.actions.single.name, 'status');
      expect(c.actionSteps, 2);
      expect(c.actionTimeout, const Duration(seconds: 15));
      final none = LlmConfig.fromEnvironment({
        'CALLTYPE_API_URL': 'https://api.example.invalid',
        'ALLOWED_HANDLES': 'CT-AAAA-0001',
        'LLM_PROVIDER': 'claude-cli',
      });
      expect(none.actions, isEmpty);
      expect(none.actionSteps, 3);
      expect(none.actionTimeout, const Duration(seconds: 60));
    });
  });

  group('directives (A2)', () {
    test('names in order, deduplicated, stripped from the text', () {
      final d = extractActionDirectives(
        'Podívám se.\n[action: status]\n[Action:LOGS ]\n[action: status]\nHned.',
      );
      expect(d.names, ['status', 'logs']);
      expect(d.text, 'Podívám se.\n\nHned.');
    });

    test('no directive: text unchanged', () {
      final d = extractActionDirectives('  Ahoj [react:👍] ');
      expect(d.names, isEmpty);
      expect(d.text, '  Ahoj [react:👍] ');
    });

    test('the prompt block names the actions, never the commands', () {
      final block = actionsPromptBlock(
        parseActions('status=systemctl --user status secret-unit'),
      );
      expect(block, contains('status'));
      expect(block, contains('[action: NAME]'));
      expect(block, isNot(contains('systemctl')));
      expect(block, isNot(contains('secret-unit')));
    });
  });

  group('launcher per OS (A4)', () {
    BridgeAction one(String cmd) => parseActions('a=$cmd').single;

    test('Linux and macOS: argv as configured, no shell', () {
      for (final os in [HostOs.linux, HostOs.macos]) {
        final r = ActionRunner([
          one('launchctl kickstart -k gui/501/ai.hermes'),
        ], os: os);
        final plan = r.launchPlan(r.actions['a']!);
        expect(plan.executable, 'launchctl');
        expect(plan.arguments, ['kickstart', '-k', 'gui/501/ai.hermes']);
        expect(plan.environment, isEmpty);
      }
    });

    test('Windows exe (schtasks): direct', () {
      final r = ActionRunner([
        one('schtasks /query /tn "Hermes Agent" /fo list'),
      ], os: HostOs.windows);
      final plan = r.launchPlan(r.actions['a']!);
      expect(plan.executable, 'schtasks');
      expect(plan.arguments, ['/query', '/tn', 'Hermes Agent', '/fo', 'list']);
    });

    test('Windows .cmd: cmd.exe /d /v:off /c with the quoted line', () {
      final r = ActionRunner([
        one(r'"C:\Users\Jan Novak\hermes\restart.cmd" now & later'),
      ], os: HostOs.windows);
      final plan = r.launchPlan(r.actions['a']!);
      expect(plan.arguments, ['/d', '/v:off', '/c', '%JAY_BRIDGE_CMDLINE%']);
      expect(
        plan.environment[windowsCmdLineVariable],
        r'"C:\Users\Jan Novak\hermes\restart.cmd" "now" "&" "later"',
      );
    });

    test('Windows .cmd with a double quote in an argument: not run', () async {
      final r = ActionRunner([one(r'x.cmd "say \"hi\""')], os: HostOs.windows);
      final result = await r.run('a');
      expect(result.exitCode, isNull);
      expect(result.error, contains('double quote'));
    });
  });

  group('runner', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('actions'));
    tearDown(() => dir.delete(recursive: true));

    Future<String> script(String name, String body) async {
      final f = File('${dir.path}/$name');
      await f.writeAsString('#!/bin/sh\n$body\n');
      await Process.run('chmod', ['+x', f.path]);
      return f.path;
    }

    test('unknown name: nothing runs, the model gets the list', () async {
      final r = ActionRunner(parseActions('status=x; restart=y'));
      final result = await r.run('rm-rf');
      expect(result.exitCode, isNull);
      expect(
        result.toPromptText(),
        '[action: rm-rf] not run: no such action. Available: status, '
        'restart. Nothing was run.',
      );
    });

    test('missing executable: not run, clear error', () async {
      final r = ActionRunner(
        parseActions('a=${dir.path}/does-not-exist --flag'),
      );
      final result = await r.run('a');
      expect(result.exitCode, isNull);
      expect(result.error, contains('cannot start'));
    });

    test('a real fake executable: exact argv, exit code, stdout + stderr, '
        'ANSI stripped, no shell expansion', () async {
      final exe = await script(
        'fake-systemctl',
        r'''for a in "$@"; do printf '<%s>\n' "$a"; done
printf '\033[1;32mactive\033[0m\r\n'
echo "warn" >&2
exit 3''',
      );
      final r = ActionRunner(
        parseActions("status=$exe --user 'a b' \$HOME '*' ';x'"),
      );
      final result = await r.run('status');
      expect(result.exitCode, 3);
      expect(result.timedOut, isFalse);
      expect(
        result.output,
        '<--user>\n<a b>\n<\$HOME>\n<*>\n<;x>\nactive\n[stderr]\nwarn',
      );
      expect(
        result.toPromptText(),
        startsWith('[action: status] exit code 3\n<--user>'),
      );
    }, testOn: 'linux || mac-os');

    test('timeout kills the process and says so', () async {
      final marker = '${dir.path}/still-running';
      final exe = await script('hang', 'sleep 30; touch "$marker"');
      final r = ActionRunner(
        parseActions('slow=$exe'),
        timeout: const Duration(milliseconds: 300),
      );
      final watch = Stopwatch()..start();
      final result = await r.run('slow');
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
      expect(result.timedOut, isTrue);
      expect(result.toPromptText(), contains('stopped after 0 s (timeout)'));
    }, testOn: 'linux || mac-os');

    test('output cap: only the last 8 KiB reach the model', () async {
      final exe = await script(
        'chatty',
        r'i=0; while [ $i -lt 3000 ]; do echo "line $i"; i=$((i+1)); done',
      );
      final r = ActionRunner(parseActions('logs=$exe'));
      final result = await r.run('logs');
      expect(result.exitCode, 0);
      expect(result.output.length, lessThanOrEqualTo(actionOutputChars));
      expect(result.output, startsWith('[... earlier output cut]'));
      expect(result.output, endsWith('line 2999'));
      expect(result.output, isNot(contains('line 0\n')));
    }, testOn: 'linux || mac-os');
  });

  test('stripAnsi: colors, cursor codes, titles', () {
    expect(stripAnsi('\x1B[31mred\x1B[0m \x1B[2K\x1B]0;title\x07ok'), 'red ok');
  });
}
