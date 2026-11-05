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
///                        (Bearer key); unset = endpoint off.
/// - `BRIDGE_PORT`        port of that endpoint (default 8650).
/// `PEER_REPLY_LIMIT` / `PEER_REPLY_WINDOW_MINUTES` are obsolete (logged, ignored).
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

  // Bot-to-bot limits now come from each group's "Bot conversation" setting;
  // this is only the operator's ceiling over all of them.
  final peerTurnsCap = positiveInt('PEER_MAX_TURNS_CAP', 50);
  // The local POST /send endpoint (see README). No key = no endpoint.
  final sendKey = env['BRIDGE_SEND_KEY']?.trim() ?? '';
  final sendPort = positiveInt('BRIDGE_PORT', 8650);

  final hermes = HermesClient(
    baseUrl: env['HERMES_URL'] ?? 'http://127.0.0.1:8642',
    apiKey: required('HERMES_API_KEY'),
    timeout: Duration(
      seconds: int.tryParse(env['HERMES_TIMEOUT_SECONDS'] ?? '') ?? 300,
    ),
  );

  final CallTypeBot bot;
  try {
    bot = await CallTypeBot.start(
      apiBaseUrl: required('CALLTYPE_API_URL'),
      storePath: required('BOT_STORE_PATH'),
      displayName: env['BOT_DISPLAY_NAME'] ?? 'Hermes',
      log: log,
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
    peerTurnsCap: peerTurnsCap,
    backend: hermes.ask,
    log: log,
  );
  log('Connected. Waiting for messages.');

  final HttpServer? endpoint;
  try {
    endpoint = await startSendEndpoint(
      key: sendKey,
      port: sendPort,
      send: bridge.sendFromLocal,
      log: log,
    );
  } on SocketException catch (error) {
    stderr.writeln('Cannot listen on 127.0.0.1:$sendPort: $error');
    exit(78); // EX_CONFIG
  }
  if (endpoint == null) log('BRIDGE_SEND_KEY not set: local /send is off.');

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
