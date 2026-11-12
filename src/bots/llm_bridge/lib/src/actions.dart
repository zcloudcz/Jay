/// Named actions the bridge runs for the model (spec
/// 2026-11-12-llm-bridge-fallback-rescue A1-A4, A7): the owner configures
/// `name=command line` pairs, the model asks for a NAME with a line
/// `[action: NAME]`, and the bridge runs exactly that configured command,
/// without a shell and without arguments from the model.
library;

import 'dart:async';
import 'dart:io';

import 'config.dart' show ConfigException;
import 'os_process.dart';

/// Action names: lower-case letters, digits and dashes.
final actionNamePattern = RegExp(r'^[a-z0-9-]{1,32}$');

/// At most this many actions in `LLM_ACTIONS`.
const maxActions = 20;

/// Output kept per action run (the end of it: errors come last).
const actionOutputChars = 8 * 1024;

/// One configured action.
class BridgeAction {
  const BridgeAction(this.name, this.command, this.argv);

  final String name;

  /// The command line as configured (logged at start).
  final String command;

  /// [command] split by [splitCommandLine]; never empty.
  final List<String> argv;

  @override
  String toString() => '$name=$command';
}

/// Splits [raw] at every `;` outside quotes.
List<String> splitActionList(String raw) {
  final parts = <String>[];
  final b = StringBuffer();
  String? quote;
  for (var i = 0; i < raw.length; i++) {
    final c = raw[i];
    if (quote == null && c == ';') {
      parts.add(b.toString());
      b.clear();
      continue;
    }
    if (quote == null && (c == '"' || c == "'")) {
      quote = c;
    } else if (quote == '"' && c == r'\' && i + 1 < raw.length) {
      // `\"` stays one escaped quote: copy both characters.
      if (raw[i + 1] == '"') {
        b
          ..write(c)
          ..write(raw[++i]);
        continue;
      }
    } else if (c == quote) {
      quote = null;
    }
    b.write(c);
  }
  parts.add(b.toString());
  return parts;
}

/// Splits a configured command line into argv. The rules (README "Rescue
/// bot"), the same on every OS:
/// - spaces and tabs separate arguments;
/// - `'...'` is literal;
/// - `"..."` is literal except `\"`, which is a quote;
/// - a backslash anywhere else is a plain character (Windows paths);
/// - quoted and unquoted parts touching each other form one argument, and
///   `""` is an empty argument.
///
/// Throws [FormatException] on an unclosed quote.
List<String> splitCommandLine(String line) {
  final args = <String>[];
  final b = StringBuffer();
  var started = false;
  String? quote;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (quote == "'") {
      if (c == "'") {
        quote = null;
      } else {
        b.write(c);
      }
    } else if (quote == '"') {
      if (c == r'\' && i + 1 < line.length && line[i + 1] == '"') {
        b.write('"');
        i++;
      } else if (c == '"') {
        quote = null;
      } else {
        b.write(c);
      }
    } else if (c == ' ' || c == '\t') {
      if (started) {
        args.add(b.toString());
        b.clear();
        started = false;
      }
    } else if (c == '"' || c == "'") {
      quote = c;
      started = true;
    } else {
      b.write(c);
      started = true;
    }
  }
  if (quote != null) {
    throw FormatException('unclosed $quote quote', line);
  }
  if (started) args.add(b.toString());
  return args;
}

/// `LLM_ACTIONS` -> actions; empty or unset = none. Throws
/// [ConfigException] on a bad name, a duplicate, an empty command, an
/// unclosed quote or more than [maxActions].
List<BridgeAction> parseActions(String? raw) {
  final actions = <BridgeAction>[];
  if (raw == null || raw.trim().isEmpty) return actions;
  for (final part in splitActionList(raw)) {
    if (part.trim().isEmpty) continue;
    final eq = part.indexOf('=');
    if (eq < 0) {
      throw ConfigException(
        'LLM_ACTIONS: "${part.trim()}" is not name=command (separate '
        'actions with ;).',
      );
    }
    final name = part.substring(0, eq).trim();
    final command = part.substring(eq + 1).trim();
    if (!actionNamePattern.hasMatch(name)) {
      throw ConfigException(
        'LLM_ACTIONS: action name "$name" must be 1-32 characters a-z, 0-9 '
        'or -.',
      );
    }
    if (actions.any((a) => a.name == name)) {
      throw ConfigException('LLM_ACTIONS: action "$name" is listed twice.');
    }
    final List<String> argv;
    try {
      argv = splitCommandLine(command);
    } on FormatException catch (e) {
      throw ConfigException('LLM_ACTIONS: action "$name": ${e.message}.');
    }
    if (argv.isEmpty || argv.first.isEmpty) {
      throw ConfigException('LLM_ACTIONS: action "$name" has no command.');
    }
    actions.add(BridgeAction(name, command, argv));
  }
  if (actions.length > maxActions) {
    throw ConfigException(
      'LLM_ACTIONS: at most $maxActions actions, got ${actions.length}.',
    );
  }
  return actions;
}

/// `[action: NAME]` as the model writes it.
final actionDirectivePattern = RegExp(
  r'\[action:\s*([^\]\n]*?)\s*\]',
  caseSensitive: false,
);

/// Finds every `[action: NAME]` in [text]: the names in order (duplicates
/// removed) and the text without them.
({String text, List<String> names}) extractActionDirectives(String text) {
  final names = <String>[];
  for (final m in actionDirectivePattern.allMatches(text)) {
    final name = m.group(1)!.trim().toLowerCase();
    if (!names.contains(name)) names.add(name);
  }
  if (names.isEmpty) return (text: text, names: names);
  final stripped = text
      .replaceAll(actionDirectivePattern, '')
      .split('\n')
      .map((l) => l.trimRight())
      .join('\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
  return (text: stripped, names: names);
}

/// The system prompt block that tells the model which actions exist (names
/// only, never the commands).
String actionsPromptBlock(Iterable<BridgeAction> actions) {
  final names = actions.map((a) => a.name).join(', ');
  return 'Actions: you can run these named actions on the computer this bot '
      'runs on: $names. To run one, write a line [action: NAME] in your '
      'answer (one line per action). The bridge runs exactly the command the '
      'owner configured for that name and sends you its exit code and output '
      'in the next message; then answer the user. You cannot pass arguments '
      'or run anything else. Never claim that an action ran or worked before '
      'you have seen its result.';
}

/// What one action run produced.
class ActionResult {
  const ActionResult({
    required this.name,
    this.exitCode,
    this.output = '',
    this.timedOut = false,
    this.error,
    this.timeout = Duration.zero,
  });

  final String name;

  /// Null when the process never ran ([error] says why).
  final int? exitCode;

  /// The end of stdout + stderr (ANSI codes removed, at most
  /// [actionOutputChars]).
  final String output;
  final bool timedOut;
  final String? error;
  final Duration timeout;

  /// One line for the log.
  String get summary => error != null
      ? 'not run ($error)'
      : timedOut
      ? 'killed after ${timeout.inSeconds} s'
      : 'exit $exitCode';

  /// The block the model reads.
  String toPromptText() {
    final head = error != null
        ? '[action: $name] not run: $error'
        : timedOut
        ? '[action: $name] stopped after ${timeout.inSeconds} s (timeout), '
              'exit code $exitCode'
        : '[action: $name] exit code $exitCode';
    if (error != null) return head;
    return '$head\n${output.trim().isEmpty ? '(no output)' : output.trimRight()}';
  }
}

/// The user turn that carries [results] back to the model.
String actionResultsTurn(List<ActionResult> results) => [
  '[Action results]',
  for (final r in results) r.toPromptText(),
  'Answer the user now. Ask for another action only if you need it.',
].join('\n\n');

final _ansi = RegExp(
  r'\x1B\[[0-?]*[ -/]*[@-~]|\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)|\x1B[@-Z\\-_]',
);

/// Removes terminal escape codes (colors, cursor moves, titles).
String stripAnsi(String text) => text.replaceAll(_ansi, '');

/// Runs configured actions: no shell, a time limit, bounded output.
class ActionRunner {
  ActionRunner(
    List<BridgeAction> actions, {
    this.timeout = const Duration(seconds: 60),
    HostOs? os,
  }) : actions = {for (final a in actions) a.name: a},
       os = os ?? HostOs.current;

  final Map<String, BridgeAction> actions;
  final Duration timeout;
  final HostOs os;

  Iterable<BridgeAction> get all => actions.values;

  /// How [action] starts on [os] (public for tests).
  LaunchPlan launchPlan(BridgeAction action) =>
      planLaunch(action.argv.first, action.argv.sublist(1), os: os);

  /// Runs the action called [name]; an unknown name runs nothing.
  Future<ActionResult> run(String name) async {
    final action = actions[name];
    if (action == null) {
      return ActionResult(
        name: name,
        error:
            'no such action. Available: ${actions.keys.join(', ')}. Nothing '
            'was run.',
      );
    }
    final LaunchPlan plan;
    try {
      plan = launchPlan(action);
    } on ArgumentError catch (e) {
      return ActionResult(name: name, error: '${e.message}');
    }
    final Process process;
    try {
      process = await plan.start();
    } on ProcessException catch (e) {
      return ActionResult(
        name: name,
        error: 'cannot start ${action.argv.first}: ${e.message}',
      );
    }
    final out = _Tail(actionOutputChars * 4);
    final err = _Tail(actionOutputChars * 4);
    final outSub = process.stdout.listen(out.add);
    final errSub = process.stderr.listen(err.add);
    unawaited(process.stdin.close().catchError((Object _) {}));
    var exited = false;
    var timedOut = false;
    final code = await process.exitCode.timeout(
      timeout,
      onTimeout: () async {
        timedOut = true;
        await killProcessTree(
          process,
          os: os,
          grace: const Duration(seconds: 2),
          exited: () => exited,
        );
        return process.exitCode.timeout(
          const Duration(seconds: 5),
          onTimeout: () => -1,
        );
      },
    );
    exited = true;
    // A child the command left behind may hold the pipes open: wait only
    // briefly for the rest of the output.
    await Future.wait([
      outSub.asFuture<void>(),
      errSub.asFuture<void>(),
    ]).timeout(const Duration(seconds: 2), onTimeout: () => const []);
    unawaited(outSub.cancel());
    unawaited(errSub.cancel());
    return ActionResult(
      name: name,
      exitCode: code,
      output: _combine(out.text, err.text),
      timedOut: timedOut,
      timeout: timeout,
    );
  }

  static String _combine(String stdout, String stderr) {
    final o = stripAnsi(normalizeNewlines(stdout)).trimRight();
    final e = stripAnsi(normalizeNewlines(stderr)).trimRight();
    final all = e.isEmpty ? o : '${o.isEmpty ? '' : '$o\n'}[stderr]\n$e';
    if (all.length <= actionOutputChars) return all;
    const cut = '[... earlier output cut]\n';
    return '$cut${all.substring(all.length - (actionOutputChars - cut.length))}';
  }
}

/// Keeps the last [max] bytes of a stream.
class _Tail {
  _Tail(this.max);
  final int max;
  final _bytes = <int>[];

  void add(List<int> chunk) {
    _bytes.addAll(chunk);
    if (_bytes.length > max * 2) _bytes.removeRange(0, _bytes.length - max);
  }

  String get text {
    final b = _bytes.length > max
        ? _bytes.sublist(_bytes.length - max)
        : _bytes;
    return processOutputDecoder.convert(b);
  }
}
