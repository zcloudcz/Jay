import 'dart:io';

import 'package:calltype_bot/calltype_bot.dart';
import 'package:hermes_bridge/hermes_bridge.dart';

/// Entry point: a Jay contact whose replies come from a Hermes Agent.
/// Configuration is environment-only (see README) so the same image runs
/// anywhere and no secret ever lands in a file or an argument list.
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

  await runBridge(
    bot,
    allowedHandles: parseAllowedHandles(env['ALLOWED_HANDLES']),
    backend: hermes.ask,
    log: log,
  );
  log('Connected. Waiting for messages.');

  // Let `docker stop` flush the DB instead of killing mid-write.
  Future<void> shutdown(ProcessSignal _) async {
    log('Shutting down.');
    await bot.close();
    hermes.close();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen(shutdown);
}
