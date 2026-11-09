@TestOn('linux || mac-os')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:llm_bridge/llm_bridge.dart';
import 'package:test/test.dart';

/// The CLI providers against fake `claude` / `codex` executables: shell
/// scripts that record their argv, stdin and cwd and answer like the real
/// CLIs do (claude: one JSON object; codex: the final message on stdout).
void main() {
  late Directory dir;
  late String work;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('llm_cli_test');
    work = '${dir.path}/work';
  });
  tearDown(() => dir.delete(recursive: true));

  /// Writes an executable script [name] whose body is [body] (sh).
  Future<String> fake(String name, String body) async {
    final f = File('${dir.path}/$name');
    await f.writeAsString(
      '#!/bin/sh\n'
      'printf "%s\\n" "\$@" > "${dir.path}/$name.args"\n'
      'pwd > "${dir.path}/$name.cwd"\n'
      'cat > "${dir.path}/$name.stdin"\n'
      '$body\n',
    );
    await Process.run('chmod', ['+x', f.path]);
    return f.path;
  }

  Future<List<String>> argsOf(String name) async => const LineSplitter()
      .convert(await File('${dir.path}/$name.args').readAsString());
  Future<String> stdinOf(String name) =>
      File('${dir.path}/$name.stdin').readAsString();

  const conversation = [
    ChatTurn.user('Ahoj'),
    ChatTurn.assistant('Ahoj!'),
    ChatTurn.user('Co umíš?'),
  ];

  group('claude-cli', () {
    test(
      'args, stdin transcript, system prompt file, cwd, JSON result',
      () async {
        final exe = await fake(
          'claude',
          'echo \'{"type":"result","subtype":"success","is_error":false,"result":"Umím povídat."}\'',
        );
        final p = ClaudeCliProvider(
          executable: exe,
          workDir: work,
          model: 'sonnet',
        );
        final answer = await p
            .reply(conversation, system: 'Jsi Jay bot.')
            .join();
        expect(answer, 'Umím povídat.');

        expect(await argsOf('claude'), [
          '-p',
          '--output-format',
          'json',
          '--system-prompt-file',
          '$work/system-prompt.txt',
          '--tools',
          '',
          '--no-session-persistence',
          '--disable-slash-commands',
          '--model',
          'sonnet',
        ]);
        expect(
          await File('$work/system-prompt.txt').readAsString(),
          'Jsi Jay bot.',
        );
        final stdin = await stdinOf('claude');
        expect(stdin, contains('[User]\nAhoj'));
        expect(stdin, contains('[Assistant]\nAhoj!'));
        expect(stdin, contains('[User]\nCo umíš?'));
        expect(stdin, isNot(contains('Jsi Jay bot.')));
        expect(
          (await File('${dir.path}/claude.cwd').readAsString()).trim(),
          Directory(work).resolveSymbolicLinksSync(),
        );
      },
    );

    test('a single message is sent as is', () async {
      final exe = await fake(
        'claude',
        'echo \'{"is_error":false,"result":"ok"}\'',
      );
      final p = ClaudeCliProvider(executable: exe, workDir: work);
      await p.reply(const [ChatTurn.user('Ahoj')], system: 's').join();
      expect(await stdinOf('claude'), 'Ahoj');
      expect(await argsOf('claude'), isNot(contains('--model')));
    });

    test('is_error result is an LlmException with the CLI text', () async {
      final exe = await fake(
        'claude',
        'echo \'{"is_error":true,"subtype":"success","result":"Not logged in. Please run /login"}\'; exit 1',
      );
      final p = ClaudeCliProvider(executable: exe, workDir: work);
      await expectLater(
        p.reply(conversation, system: 's').join(),
        throwsA(
          isA<LlmException>().having(
            (e) => e.message,
            'm',
            contains('Not logged in'),
          ),
        ),
      );
    });

    test('non-zero exit without JSON names the code and stderr', () async {
      final exe = await fake('claude', 'echo "boom on stderr" >&2; exit 3');
      final p = ClaudeCliProvider(executable: exe, workDir: work);
      await expectLater(
        p.reply(conversation, system: 's').join(),
        throwsA(
          isA<LlmException>().having(
            (e) => e.message,
            'm',
            allOf(contains('code 3'), contains('boom on stderr')),
          ),
        ),
      );
    });

    test('missing executable: a clear install hint', () async {
      final p = ClaudeCliProvider(
        executable: '${dir.path}/nope',
        workDir: work,
      );
      await expectLater(
        p.reply(conversation, system: 's').join(),
        throwsA(
          isA<LlmException>().having(
            (e) => e.message,
            'm',
            contains('Install it'),
          ),
        ),
      );
    });

    test('cancelling (bridge timeout) kills the process', () async {
      final exe = await fake(
        'claude',
        'echo \$\$ > "${dir.path}/pid"; exec sleep 30',
      );
      final p = ClaudeCliProvider(executable: exe, workDir: work);
      final sub = p.reply(conversation, system: 's').listen((_) {});
      final pidFile = File('${dir.path}/pid');
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!pidFile.existsSync() ||
          pidFile.readAsStringSync().trim().isEmpty) {
        if (DateTime.now().isAfter(deadline)) fail('fake CLI never started');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final pid = pidFile.readAsStringSync().trim();
      await sub.cancel();
      // `kill -0` fails once the process is gone.
      var alive = true;
      for (var i = 0; i < 100 && alive; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        alive = (await Process.run('kill', ['-0', pid])).exitCode == 0;
      }
      expect(alive, isFalse);
    });
  });

  group('codex-cli', () {
    test(
      'args, instructions lead the stdin prompt, stdout is the answer',
      () async {
        final exe = await fake(
          'codex',
          'echo "progress noise" >&2; printf "Umím povídat.\\n"',
        );
        final p = CodexCliProvider(
          executable: exe,
          workDir: work,
          model: 'gpt-6.1-sol',
        );
        final answer = await p
            .reply(conversation, system: 'Jsi Jay bot.')
            .join();
        expect(answer, 'Umím povídat.');
        expect(await argsOf('codex'), [
          'exec',
          '--skip-git-repo-check',
          '--ephemeral',
          '--sandbox',
          'read-only',
          '--color',
          'never',
          '-m',
          'gpt-6.1-sol',
          '-',
        ]);
        final stdin = await stdinOf('codex');
        expect(stdin, startsWith('[Instructions]\nJsi Jay bot.'));
        expect(stdin, contains('[User]\nCo umíš?'));
        expect(stdin.trimRight(), endsWith('Write only the reply text.'));
      },
    );

    test('non-zero exit is an LlmException with a login hint', () async {
      final exe = await fake('codex', 'echo "not authenticated" >&2; exit 1');
      final p = CodexCliProvider(executable: exe, workDir: work);
      await expectLater(
        p.reply(conversation, system: 's').join(),
        throwsA(
          isA<LlmException>().having(
            (e) => e.message,
            'm',
            allOf(contains('not authenticated'), contains('codex login')),
          ),
        ),
      );
    });
  });

  test(
    'bridge timeout over a hanging CLI answers with the timeout text',
    () async {
      final exe = await fake('claude', 'exec sleep 30');
      final store = await openTestHistory(dir.path);
      final sink = RecordingSink();
      final bridge = LlmBridge(
        provider: ClaudeCliProvider(executable: exe, workDir: work),
        history: store,
        displayName: 'Bot',
        systemPrompt: 's',
        timeout: const Duration(milliseconds: 500),
        progressAfter: Duration.zero,
      );
      await bridge
          .handle(conversationId: 'c', text: 'hi', sink: sink)
          .timeout(const Duration(seconds: 10));
      expect(sink.replies.single, contains('did not answer within'));
      expect(await store.history('c'), isEmpty);
    },
  );
}

Future<HistoryStore> openTestHistory(String dir) => HistoryStore.open(
  '$dir/bot.store.llm',
  base64Decode(base64Encode(List.filled(32, 7))),
  cap: 20,
);

class RecordingSink implements ChatSink {
  final replies = <String>[];
  @override
  Future<ProgressHandle> progress(String text) async =>
      throw UnimplementedError();
  @override
  Future<void> reply(String text) async => replies.add(text);
}
