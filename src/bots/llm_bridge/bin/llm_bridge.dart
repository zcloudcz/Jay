import 'dart:io';
import 'dart:typed_data';

import 'package:calltype_bot/calltype_bot.dart';
import 'package:llm_bridge/llm_bridge.dart';
import 'package:llm_bridge/src/jay_glue.dart';

/// Entry point: a Jay contact whose replies come from an LLM.
/// Configuration is environment-only (see README) so the same binary runs
/// as a user service, in Docker or by hand, and no secret lands in an
/// argument list or shell history.
Future<void> main() async {
  void log(String line) =>
      stdout.writeln('${DateTime.now().toUtc().toIso8601String()} $line');

  // Everything that can be checked offline is checked before the first
  // network call, so a typo fails in a second with one clear line.
  final LlmConfig config;
  final Uint8List storeKey;
  try {
    config = LlmConfig.fromEnvironment(Platform.environment);
    storeKey = EncryptedFileStore.parseKey(
      Platform.environment['BOT_STORE_KEY'],
    );
  } on ConfigException catch (e) {
    stderr.writeln('llm_bridge: configuration error: ${e.message}');
    exit(78); // EX_CONFIG
  } on StateError catch (e) {
    stderr.writeln('llm_bridge: configuration error: ${e.message}');
    exit(78); // EX_CONFIG
  }

  final provider = buildProvider(config, log: log);
  log('Provider: ${provider.label}.');
  // Names and commands only: commands carry no secrets by contract (A1).
  final actions = config.actions.isEmpty
      ? null
      : ActionRunner(config.actions, timeout: config.actionTimeout);
  if (actions != null) {
    log(
      'Actions (owners in 1:1 chats only, max ${config.actionSteps} rounds '
      'per message): ${config.actions.join('; ')}.',
    );
  }
  final imageGenerator = buildImageGenerator(config);
  if (imageGenerator != null) log('Image generation: ${imageGenerator.label}.');

  final HistoryStore history;
  try {
    history = await HistoryStore.open(
      config.statePath,
      storeKey,
      cap: config.historyMessages,
      log: log,
    );
  } on FileSystemException catch (e) {
    stderr.writeln('llm_bridge: cannot open ${config.statePath}: ${e.message}');
    exit(73); // EX_CANTCREAT
  }

  final CallTypeBot bot;
  try {
    bot = await CallTypeBot.start(
      apiBaseUrl: config.apiUrl,
      storePath: config.storePath,
      displayName: config.displayName,
      log: log,
    );
  } on StateError catch (error) {
    // Store key problems: a clear one-liner beats a stack trace.
    stderr.writeln('llm_bridge: ${error.message}');
    exit(78); // EX_CONFIG
  } catch (error) {
    stderr.writeln(
      'llm_bridge: cannot reach the Jay API ${config.apiUrl}: $error',
    );
    exit(69); // EX_UNAVAILABLE
  }
  // The setup scripts wait for this line (handle + invite).
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
    stderr.writeln('llm_bridge: ${e.message}');
    await bot.close();
    exit(78); // EX_CONFIG
  }

  final bridge = LlmBridge(
    provider: provider,
    history: history,
    displayName: config.displayName,
    systemPrompt: config.systemPrompt,
    timeout: config.timeout,
    progressAfter: config.progressAfter,
    imageGenerator: imageGenerator,
    mediaDir: config.mediaDir,
    retryRateLimit: config.fallbacks.isEmpty,
    actions: actions,
    actionSteps: config.actionSteps,
    log: log,
  );
  await runJayGlue(
    bot,
    bridge: bridge,
    allowedIds: allowedIds,
    groupReplies: config.groupReplies,
    peerTurnsCap: config.peerTurnsCap,
    inbound: config.inbound,
    imageMaxBytes: config.imageMaxBytes,
    ackReactions: config.ackReactions,
    log: log,
  );
  log(
    'Connected. Waiting for messages (acknowledgement reactions: '
    '${config.ackReactions ? 'on' : 'off'}).',
  );

  if (config.greeting) {
    await greetOwners(
      handles: allowedIds.values,
      store: history,
      send: (handle, text) => bot.send(to: handle, text: text),
      displayName: config.displayName,
      log: log,
    );
  }

  // Let `docker stop` / the service manager flush the stores instead of
  // killing mid-write.
  Future<void> shutdown(ProcessSignal _) async {
    log('Shutting down.');
    await bot.close();
    await provider.close();
    await imageGenerator?.close();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen(shutdown);
}
