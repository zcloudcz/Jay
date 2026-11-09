import 'dart:io';

import 'package:calltype_bot/calltype_bot.dart';
import 'package:hermes_bridge/hermes_bridge.dart';

/// Entry point: a Jay contact whose replies come from a Hermes Agent.
/// Configuration is environment-only (see README) so the same image runs
/// anywhere and no secret ever lands in a file or an argument list.
///
/// Bot conversations and the local send endpoint:
/// - `PEER_BOT_HANDLES`   optional; only these bots may talk to this one
///                        (narrows the group setting, never widens it).
/// - `PEER_MAX_TURNS_CAP` ceiling for any group's bot-only exchange (default 50).
/// - `BRIDGE_SEND_KEY`    enables `POST http://127.0.0.1:$BRIDGE_PORT/send`
///                        and `/react` (Bearer key); unset = endpoint off.
/// - `BRIDGE_PORT`        port of that endpoint (default 8650).
/// `PEER_REPLY_LIMIT` / `PEER_REPLY_WINDOW_MINUTES` are obsolete (logged, ignored).
///
/// Agent messaging (all optional):
/// - `HERMES_STREAM`          `true` (default): stream turns over SSE; `false`
///                            = plain `/chat` (no progress, no approvals).
/// - `PROGRESS_AFTER_SECONDS` progress message after N s without an answer
///                            (default 8, 0 = never).
/// - `PROGRESS_EDIT_SECONDS`  min seconds between progress edits (default 5).
/// - `PROGRESS_MAX_EDITS`     progress edits per turn (default 30).
/// - `BOT_COMMANDS`           `cmd:description;cmd2:description` for the "/" menu.
/// - `REACTION_MODE`          what an owner's emoji reaction does: `silent`
///                            (default: one Hermes turn, answer not posted),
///                            `batch` (sent along with the next message),
///                            `reply` (normal turn, answer posted), `off`.
///
/// Hermes may start an answer with a line `[react:EMOJI]` to react to the
/// owner's message (`[react:]` removes it; only that line = no text), see
/// README "The bot reacting".
///
/// Timeouts (all optional):
/// - `HERMES_ASK_TIMEOUT_SECONDS` longest wait for a Hermes answer (plain
///                            `/chat`) or longest silence (stream); default
///                            300. `HERMES_TIMEOUT_SECONDS` is the older name
///                            of the same setting (used when the new one is
///                            unset).
/// - `JAY_SERVER_TIMEOUT_SECONDS` silence from the Jay hub after which the
///                            session counts as dead and is reconnected
///                            (default 60, minimum 20; the hub pings every 15 s).
Future<void> main() async {
  final env = Platform.environment;
  String required(String name) {
    final value = env[name]?.trim() ?? '';
    if (value.isEmpty) {
      stderr.writeln('Missing required environment variable $name.');
      exit(64); // EX_USAGE
    }
    return value;
  }

  void log(String line) =>
      stdout.writeln('${DateTime.now().toUtc().toIso8601String()} $line');

  int positiveInt(String name, int fallback) {
    final raw = env[name]?.trim() ?? '';
    if (raw.isEmpty) return fallback;
    final value = int.tryParse(raw);
    if (value == null || value <= 0) {
      stderr.writeln('$name must be a positive integer, got "$raw".');
      exit(78); // EX_CONFIG
    }
    return value;
  }

  int nonNegativeInt(String name, int fallback) {
    final raw = env[name]?.trim() ?? '';
    if (raw.isEmpty) return fallback;
    final value = int.tryParse(raw);
    if (value == null || value < 0) {
      stderr.writeln('$name must be a non-negative integer, got "$raw".');
      exit(78); // EX_CONFIG
    }
    return value;
  }

  final streamRaw = (env['HERMES_STREAM'] ?? '').trim().toLowerCase();
  final useStream = !const {'false', '0', 'no', 'off'}.contains(streamRaw);
  final progress = ProgressSettings(
    after: Duration(seconds: nonNegativeInt('PROGRESS_AFTER_SECONDS', 8)),
    editInterval: Duration(seconds: nonNegativeInt('PROGRESS_EDIT_SECONDS', 5)),
    maxEdits: nonNegativeInt('PROGRESS_MAX_EDITS', 30),
  );
  final List<BotCommand> commands;
  try {
    commands = parseBotCommands(env['BOT_COMMANDS']);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exit(78); // EX_CONFIG
  }

  final ReactionMode reactionMode;
  try {
    reactionMode = parseReactionMode(env['REACTION_MODE']);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exit(78); // EX_CONFIG
  }

  // Bot-to-bot limits now come from each group's "Bot conversation" setting;
  // this is only the operator's ceiling over all of them.
  final peerTurnsCap = positiveInt('PEER_MAX_TURNS_CAP', 50);
  // The local POST /send endpoint (see README). No key = no endpoint.
  final sendKey = env['BRIDGE_SEND_KEY']?.trim() ?? '';
  final sendPort = positiveInt('BRIDGE_PORT', 8650);

  // The new name wins and is validated; the old one keeps its old lenient
  // parsing (anything unusable = 300) so existing deployments start as before.
  final oldAskTimeout = int.tryParse(env['HERMES_TIMEOUT_SECONDS'] ?? '');
  final askTimeout = Duration(
    seconds: positiveInt(
      'HERMES_ASK_TIMEOUT_SECONDS',
      oldAskTimeout != null && oldAskTimeout > 0 ? oldAskTimeout : 300,
    ),
  );
  final hubTimeout = Duration(
    seconds: positiveInt('JAY_SERVER_TIMEOUT_SECONDS', 60),
  );
  if (hubTimeout < const Duration(seconds: 20)) {
    // Below ~1 missed server ping every healthy session would be dropped.
    stderr.writeln('JAY_SERVER_TIMEOUT_SECONDS must be at least 20.');
    exit(78); // EX_CONFIG
  }

  final hermes = HermesClient(
    baseUrl: env['HERMES_URL'] ?? 'http://127.0.0.1:8642',
    apiKey: required('HERMES_API_KEY'),
    timeout: askTimeout,
    stream: useStream,
    log: log,
  );

  final CallTypeBot bot;
  try {
    bot = await CallTypeBot.start(
      apiBaseUrl: required('CALLTYPE_API_URL'),
      storePath: required('BOT_STORE_PATH'),
      displayName: env['BOT_DISPLAY_NAME'] ?? 'Hermes',
      log: log,
      hubServerTimeout: hubTimeout,
    );
  } on StateError catch (error) {
    // Store key problems: a clear one-liner beats a stack trace.
    stderr.writeln(error.message);
    exit(78); // EX_CONFIG
  } catch (error) {
    // API unreachable on first registration. Exit non-zero and let the
    // container restart policy retry — there is nothing to serve yet.
    stderr.writeln('Cannot reach the CallType API: $error');
    exit(69); // EX_UNAVAILABLE
  }
  log('Bot ${bot.handle} starting — invite: ${bot.inviteLink}');
  log(
    'Hermes timeout ${askTimeout.inSeconds} s, Jay hub reconnects after '
    '${hubTimeout.inSeconds} s of silence.',
  );

  for (final old in ['PEER_REPLY_LIMIT', 'PEER_REPLY_WINDOW_MINUTES']) {
    if ((env[old] ?? '').trim().isNotEmpty) {
      log(
        '$old is no longer used: limits come from the group setting '
        '"Bot conversation"; PEER_MAX_TURNS_CAP is the operator ceiling.',
      );
    }
  }

  final bridge = await runBridge(
    bot,
    allowedHandles: parseAllowedHandles(env['ALLOWED_HANDLES']),
    peerHandles: parseAllowedHandles(env['PEER_BOT_HANDLES']),
    inbound: env[botInboundEnv],
    peerTurnsCap: peerTurnsCap,
    stream: hermes.chat,
    approve: hermes.approve,
    progress: progress,
    reactions: reactionMode,
    log: log,
  );
  log('Connected. Waiting for messages (reactions: ${reactionMode.name}).');
  if (commands.isNotEmpty) {
    try {
      await bot.setCommands(commands);
      log('Published ${commands.length} bot command(s).');
    } catch (error) {
      // An older server has no bot-commands endpoint: the "/" menu is a
      // convenience, the bot works without it.
      log('Could not publish BOT_COMMANDS: $error');
    }
  }

  final HttpServer? endpoint;
  try {
    endpoint = await startSendEndpoint(
      key: sendKey,
      port: sendPort,
      send: bridge.sendFromLocal,
      react: bridge.reactFromLocal,
      log: log,
    );
  } on SocketException catch (error) {
    stderr.writeln('Cannot listen on 127.0.0.1:$sendPort: $error');
    exit(78); // EX_CONFIG
  }
  if (endpoint == null) {
    log('BRIDGE_SEND_KEY not set: local /send and /react are off.');
  }

  // Let `docker stop` flush the DB instead of killing mid-write.
  Future<void> shutdown(ProcessSignal _) async {
    log('Shutting down.');
    await endpoint?.close(force: true);
    await bot.close();
    hermes.close();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen(shutdown);
}
