import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'http_providers.dart' show normalizeTurns;
import 'provider.dart';

/// Renders a conversation as one prompt for a CLI that takes a single
/// message per run (no session is kept between runs, see the providers).
String transcriptPrompt(List<ChatTurn> conversation, {String? instructions}) {
  final turns = normalizeTurns(conversation);
  final b = StringBuffer();
  if (instructions != null && instructions.trim().isNotEmpty) {
    b
      ..writeln('[Instructions]')
      ..writeln(instructions.trim())
      ..writeln();
  }
  if (turns.length == 1 && b.isEmpty) return turns.single.text;
  if (turns.length > 1) {
    b.writeln('Conversation so far, oldest first:');
    b.writeln();
  }
  for (final t in turns) {
    b
      ..writeln(t.role == 'user' ? '[User]' : '[Assistant]')
      ..writeln(t.text)
      ..writeln();
  }
  b.write(
    'Reply to the last [User] message as the assistant. Write only the '
    'reply text.',
  );
  return b.toString();
}

/// Runs a local, already signed-in vendor CLI as a subprocess.
///
/// WHY a subprocess and never a token: Anthropic does not allow third-party
/// apps to collect, store or route Claude.ai subscription credentials
/// (code.claude.com/docs/en/legal-and-compliance). The owner installs the
/// unmodified CLI and signs in through the vendor's own flow; this bridge
/// only starts it for the owner's own messages and never reads its login.
///
/// The prompt goes through stdin, not argv: argv is visible to every user
/// of the machine (`ps`) and limited to ~32 KB on Windows.
abstract class CliProvider implements LlmProvider {
  CliProvider({
    required this.executable,
    required this.workDir,
    this.model,
    this.timeoutKill = const Duration(seconds: 5),
  });

  final String executable;

  /// An empty directory the CLI runs in: it must not pick up a project's
  /// settings, hooks or MCP servers from wherever the service started.
  final String workDir;
  final String? model;
  final Duration timeoutKill;

  /// Arguments of one run, public for tests.
  List<String> arguments(String system);

  /// The stdin text of one run.
  String stdinText(List<ChatTurn> conversation, String system);

  /// The answer from the process output, or throws [LlmException].
  String parseOutput(String stdout, String stderr, int exitCode);

  String get cliName;

  @override
  Stream<String> reply(List<ChatTurn> conversation, {required String system}) {
    late final StreamController<String> controller;
    Process? process;
    var finished = false;
    Future<void> run() async {
      try {
        await Directory(workDir).create(recursive: true);
        await prepare(system);
        try {
          process = await Process.start(
            executable,
            arguments(system),
            workingDirectory: workDir,
            // npm installs `claude.cmd` / `codex.cmd` on Windows, which
            // only a shell can start; the native installers ship .exe.
            runInShell:
                Platform.isWindows &&
                RegExp(
                  r'\.(cmd|bat)$',
                  caseSensitive: false,
                ).hasMatch(executable),
          );
        } on ProcessException catch (e) {
          throw LlmException(
            '$cliName was not found or cannot start ($executable: ${e.message}). '
            'Install it and sign in on this computer, then restart the bot.',
          );
        }
        final p = process!;
        final out = p.stdout.transform(utf8.decoder).join();
        final err = p.stderr.transform(utf8.decoder).join();
        p.stdin.add(utf8.encode(stdinText(conversation, system)));
        await p.stdin.close().catchError((Object _) {});
        final code = await p.exitCode;
        finished = true;
        if (controller.isClosed) return;
        final answer = parseOutput(await out, await err, code);
        controller.add(answer);
      } catch (e, st) {
        if (!controller.isClosed) controller.addError(e, st);
      } finally {
        finished = true;
        if (!controller.isClosed) unawaited(controller.close());
      }
    }

    controller = StreamController<String>(
      onListen: run,
      // The bridge cancels on its timeout: the CLI must not keep running
      // (and spending the owner's quota) for an answer nobody waits for.
      onCancel: () {
        final p = process;
        if (p != null && !finished) {
          p.kill();
          Timer(timeoutKill, () {
            if (!finished) p.kill(ProcessSignal.sigkill);
          });
        }
      },
    );
    return controller.stream;
  }

  /// Hook before the process starts (e.g. writing the system prompt file).
  Future<void> prepare(String system) async {}

  static String excerpt(String text, [int max = 300]) {
    final t = text.trim();
    return t.length <= max ? t : '...${t.substring(t.length - max)}';
  }

  @override
  Future<void> close() async {}
}

/// `claude -p` (Claude Code print mode) with the owner's own login.
///
/// Flags per code.claude.com/docs/en/cli-reference (checked 2026-11-09):
/// `-p` print mode, `--output-format json` (answer in `result`, failure in
/// `is_error`), `--system-prompt-file` replaces Claude Code's coding prompt
/// with the bot's, `--tools ""` disables every built-in tool (a chat
/// contact must not run commands on the owner's machine),
/// `--no-session-persistence` keeps the chats out of `~/.claude` (the
/// bridge keeps its own encrypted history), `--disable-slash-commands`
/// keeps skills out. NOT `--bare`: bare mode ignores the subscription
/// login and needs an API key.
class ClaudeCliProvider extends CliProvider {
  ClaudeCliProvider({
    super.executable = 'claude',
    required super.workDir,
    super.model,
  });

  @override
  String get cliName => 'Claude Code (claude)';

  @override
  String get label => 'Claude Code CLI${model == null ? '' : ' $model'}';

  String get _systemFile =>
      '$workDir${Platform.pathSeparator}system-prompt.txt';

  @override
  Future<void> prepare(String system) =>
      File(_systemFile).writeAsString(system, flush: true);

  @override
  List<String> arguments(String system) => [
    '-p',
    '--output-format',
    'json',
    '--system-prompt-file',
    _systemFile,
    '--tools',
    '',
    '--no-session-persistence',
    '--disable-slash-commands',
    if (model != null) ...['--model', model!],
  ];

  @override
  String stdinText(List<ChatTurn> conversation, String system) =>
      transcriptPrompt(conversation);

  @override
  String parseOutput(String stdout, String stderr, int exitCode) {
    Map? json;
    try {
      final decoded = jsonDecode(stdout.trim());
      if (decoded is Map) json = decoded;
    } on FormatException {
      json = null;
    }
    if (json != null) {
      final result = json['result'];
      if (json['is_error'] == true || exitCode != 0) {
        throw LlmException(
          'Claude Code failed: ${result is String && result.isNotEmpty ? excerptOf(result) : json['subtype'] ?? 'exit code $exitCode'}',
        );
      }
      if (result is String) return result;
    }
    if (exitCode != 0) {
      throw LlmException(
        'Claude Code exited with code $exitCode: '
        '${CliProvider.excerpt(stderr.isEmpty ? stdout : stderr)}'
        ' (is it signed in? Run `claude` once on this computer.)',
      );
    }
    throw LlmException(
      'Claude Code returned no JSON result: ${CliProvider.excerpt(stdout)}',
    );
  }

  static String excerptOf(String s) => CliProvider.excerpt(s);
}

/// `codex exec` (Codex CLI non-interactive mode) with the owner's own
/// ChatGPT login.
///
/// Flags per developers.openai.com/codex/noninteractive and the exec CLI
/// source (checked 2026-11-09): `exec` prints only the final agent message
/// to stdout (progress goes to stderr); `-` reads the prompt from stdin;
/// `--skip-git-repo-check` because the work dir is not a repository;
/// `--ephemeral` keeps the chats out of `~/.codex`; `--sandbox read-only`
/// (also the default) so the agent cannot change files; `--color never`
/// keeps escape codes out. Codex has no system prompt flag, so the bot's
/// prompt leads the stdin text.
class CodexCliProvider extends CliProvider {
  CodexCliProvider({
    super.executable = 'codex',
    required super.workDir,
    super.model,
  });

  @override
  String get cliName => 'Codex CLI (codex)';

  @override
  String get label => 'Codex CLI${model == null ? '' : ' $model'}';

  @override
  List<String> arguments(String system) => [
    'exec',
    '--skip-git-repo-check',
    '--ephemeral',
    '--sandbox',
    'read-only',
    '--color',
    'never',
    if (model != null) ...['-m', model!],
    '-',
  ];

  @override
  String stdinText(List<ChatTurn> conversation, String system) =>
      transcriptPrompt(conversation, instructions: system);

  @override
  String parseOutput(String stdout, String stderr, int exitCode) {
    if (exitCode != 0) {
      throw LlmException(
        'Codex exited with code $exitCode: '
        '${CliProvider.excerpt(stderr.isEmpty ? stdout : stderr)}'
        ' (is it signed in? Run `codex login` on this computer.)',
      );
    }
    return stdout.trim();
  }
}
