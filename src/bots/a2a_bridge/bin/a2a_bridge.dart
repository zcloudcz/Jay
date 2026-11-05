import 'dart:io';

import 'package:a2a_bridge/a2a_bridge.dart';
import 'package:a2a_bridge/src/jay_glue.dart';
import 'package:calltype_bot/calltype_bot.dart';

/// Entry point: a Jay contact whose replies come from an A2A agent.
/// Configuration is environment-only (see README) so the same image runs
/// anywhere and no secret lands in a file or an argument list.
Future<void> main() async {
  void log(String line) =>
      stdout.writeln('${DateTime.now().toUtc().toIso8601String()} $line');

  final BridgeConfig config;
  try {
    config = BridgeConfig.fromEnvironment(Platform.environment);
  } on ConfigException catch (e) {
    stderr.writeln(e.message);
    exit(78); // EX_CONFIG
  }

  final client = A2aClient(
    agentUrl: config.agentUrl,
    token: config.token,
    endpointOverride: config.endpointUrl,
    log: log,
  );
  // WHY the card comes BEFORE the bot starts: its `name` is the default
  // display name the bot registers with, and an unusable agent should stop
  // the container (restart policy retries) instead of running a mute bot.
  final AgentCard card;
  try {
    card = await client.discover();
  } on A2aConfigException catch (e) {
    stderr.writeln(e.message);
    exit(78); // EX_CONFIG
  } catch (e) {
    stderr.writeln('Cannot read the A2A agent card: $e');
    exit(69); // EX_UNAVAILABLE
  }
  log(
    'Agent "${card.name}" at ${client.endpoint} (${client.version.name}), '
    '${card.skills.length} skill(s).',
  );

  final state = await StateStore.open(config.statePath, log: log);

  final CallTypeBot bot;
  try {
    bot = await CallTypeBot.start(
      apiBaseUrl: config.apiUrl,
      storePath: config.storePath,
      displayName:
          config.displayName ?? (card.name.isEmpty ? 'Agent' : card.name),
      log: log,
    );
  } on StateError catch (error) {
    // Store key problems: a clear one-liner beats a stack trace.
    stderr.writeln(error.message);
    exit(78); // EX_CONFIG
  } catch (error) {
    stderr.writeln('Cannot reach the CallType API: $error');
    exit(69); // EX_UNAVAILABLE
  }
  log('Bot ${bot.handle} starting, invite: ${bot.inviteLink}');

  // ponytail: resolved at startup only; restart after changing
  // ALLOWED_HANDLES or after an owner reinstalls Jay (new device id).
  final Map<String, String> allowedIds;
  try {
    allowedIds = await resolveAllowedHandles(
      config.allowedHandles,
      bot.deviceIdForHandle,
      log: log,
    );
  } on ConfigException catch (e) {
    stderr.writeln(e.message);
    await bot.close();
    exit(78); // EX_CONFIG
  }

  final bridge = A2aBridge(
    client: client,
    state: state,
    card: card,
    timeout: config.timeout,
    pollInterval: config.pollInterval,
    log: log,
  );
  await runJayGlue(bot, bridge: bridge, allowedIds: allowedIds, log: log);
  log('Connected. Waiting for messages.');

  // Let `docker stop` flush the DB instead of killing mid-write.
  Future<void> shutdown(ProcessSignal _) async {
    log('Shutting down.');
    await bot.close();
    client.close();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen(shutdown);
}
