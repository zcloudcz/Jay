/// Starting and stopping child processes the same way on Linux, macOS and
/// Windows (CLI providers and bridge actions). The OS is a parameter, so
/// the Windows rules are unit-tested on any host.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The operating system rules to apply (a seam for tests).
enum HostOs {
  linux,
  macos,
  windows;

  static HostOs get current =>
      Platform.isWindows ? windows : (Platform.isMacOS ? macos : linux);

  bool get isWindows => this == windows;

  /// Path separator of this OS (Platform.pathSeparator is the host's).
  String get pathSeparator => isWindows ? r'\' : '/';
}

/// What [Process.start] gets: executable, arguments and extra environment.
class LaunchPlan {
  const LaunchPlan(
    this.executable,
    this.arguments, {
    this.environment = const {},
  });

  final String executable;
  final List<String> arguments;

  /// Added to the inherited environment.
  final Map<String, String> environment;

  Future<Process> start({String? workingDirectory}) => Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment.isEmpty ? null : environment,
  );

  @override
  String toString() => '$executable ${arguments.join(' ')}';
}

/// The environment variable that carries a batch command line to cmd.exe
/// (see [planLaunch]).
const windowsCmdLineVariable = 'JAY_BRIDGE_CMDLINE';

/// `.cmd` / `.bat`: only cmd.exe can start them on Windows.
bool isWindowsBatch(String executable) =>
    RegExp(r'\.(cmd|bat)$', caseSensitive: false).hasMatch(executable.trim());

/// How to start [executable] with [arguments] on [os].
///
/// Everything except a Windows batch file starts directly, without a shell.
/// A batch file (npm installs `claude.cmd` / `codex.cmd`, an operator may
/// configure an action `restart.cmd`) needs cmd.exe. WHY not Dart's
/// `runInShell`: it runs `cmd.exe /c <exe> <args>` with C-runtime quoting.
/// When the executable path contains a space (`C:\Users\Jan Novak\...`),
/// that line starts with a quote and has more than two, so cmd.exe strips
/// the first and the last quote and the command breaks; unquoted `&`, `|`,
/// `<`, `>` in an argument would also be run by cmd.exe. Dart cannot pass a
/// verbatim command line either (it re-quotes every argument with a quote
/// or a space). So the finished, fully quoted line travels in an
/// environment variable, and cmd.exe gets only `/c %JAY_BRIDGE_CMDLINE%`:
/// the /c text does not start with a quote (nothing is stripped), cmd.exe
/// expands the variable once (the value is never expanded again), then
/// parses the quotes, inside which `&|<>()^%` are plain text. `/d` skips
/// AutoRun commands, `/v:off` keeps `!` literal.
LaunchPlan planLaunch(
  String executable,
  List<String> arguments, {
  HostOs? os,
  String? comSpec,
}) {
  final host = os ?? HostOs.current;
  if (!host.isWindows || !isWindowsBatch(executable)) {
    return LaunchPlan(executable, arguments);
  }
  final line = [executable, ...arguments].map(quoteForCmd).join(' ');
  return LaunchPlan(
    comSpec ?? _comSpec(),
    const ['/d', '/v:off', '/c', '%$windowsCmdLineVariable%'],
    environment: {windowsCmdLineVariable: line},
  );
}

String _comSpec() {
  final v = Platform.environment['ComSpec'] ?? '';
  return v.trim().isEmpty ? 'cmd.exe' : v;
}

/// One argument of a cmd.exe line for a batch file: always double-quoted
/// (so cmd.exe and the batch's `%*` treat `&|<>()^,;=` and spaces as text),
/// backslashes before the closing quote doubled (C-runtime rule, so the
/// program the batch starts reads the same string back).
///
/// Throws [ArgumentError] for a double quote or a line break: no quoting
/// passes them through cmd.exe and a batch file intact.
String quoteForCmd(String arg) {
  if (arg.contains('"') || arg.contains('\n') || arg.contains('\r')) {
    throw ArgumentError.value(
      arg,
      'arg',
      'a double quote or a line break cannot be passed to a .cmd/.bat file',
    );
  }
  var trailing = 0;
  while (trailing < arg.length && arg[arg.length - 1 - trailing] == r'\') {
    trailing++;
  }
  return '"$arg${r'\' * trailing}"';
}

/// Extra commands that stop the whole process tree of [pid] on [os].
///
/// WHY on Windows: a batch file runs under cmd.exe, and killing cmd.exe
/// leaves its child (node running Claude Code or Codex) alive, still
/// spending the owner's quota. `taskkill /T /F` ends the tree. On Linux and
/// macOS the CLI is the process itself (a `#!` script is exec'd), so a
/// signal to it is enough.
List<List<String>> treeKillCommands(int pid, HostOs os) => os.isWindows
    ? [
        ['taskkill', '/PID', '$pid', '/T', '/F'],
      ]
    : const [];

/// Stops [process]: on Windows the whole tree at once; elsewhere SIGTERM,
/// then SIGKILL after [grace] unless [exited] says it is gone.
Future<void> killProcessTree(
  Process process, {
  HostOs? os,
  Duration grace = const Duration(seconds: 5),
  bool Function()? exited,
}) async {
  final host = os ?? HostOs.current;
  for (final cmd in treeKillCommands(process.pid, host)) {
    try {
      await Process.run(cmd.first, cmd.sublist(1));
    } on ProcessException {
      // taskkill missing: the plain kill below still ends the direct child.
    }
  }
  process.kill();
  if (host.isWindows) return; // TerminateProcess: already final.
  Timer(grace, () {
    if (exited == null || !exited()) process.kill(ProcessSignal.sigkill);
  });
}

/// Decodes process output. WHY `allowMalformed`: Windows tools write in the
/// console code page (a localized "is not recognized" message, schtasks in
/// Czech), which is not UTF-8; a strict decoder would throw and the real
/// error text would be lost.
const processOutputDecoder = Utf8Decoder(allowMalformed: true);

/// CRLF and lone CR become LF (Windows programs end lines with CRLF).
String normalizeNewlines(String text) =>
    text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
