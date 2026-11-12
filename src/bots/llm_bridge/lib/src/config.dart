/// Environment configuration of the LLM bridge, parsed in pure Dart so the
/// fail-closed rules are unit-tested.
library;

import 'access.dart' show GroupReplies;
import 'actions.dart' show BridgeAction, parseActions;
import 'images.dart' show defaultImageMaxBytes, imageMaxBytesCeiling;

/// A configuration error: the process exits with EX_CONFIG and this text.
class ConfigException implements Exception {
  const ConfigException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Where the answers come from (`LLM_PROVIDER`).
enum LlmProviderKind {
  /// Anthropic Messages API with the owner's API key.
  anthropic('anthropic'),

  /// OpenAI Chat Completions or any compatible endpoint (`OPENAI_BASE_URL`).
  openai('openai'),

  /// The owner's own, already signed-in Claude Code CLI (`claude -p`).
  claudeCli('claude-cli'),

  /// The owner's own, already signed-in Codex CLI (`codex exec`).
  codexCli('codex-cli');

  const LlmProviderKind(this.id);
  final String id;

  static LlmProviderKind? parse(String raw) {
    for (final k in values) {
      if (k.id == raw.trim().toLowerCase()) return k;
    }
    return null;
  }
}

/// Defaults, in one place so README, script and tests agree.
abstract final class LlmDefaults {
  /// Claude Sonnet 5.5: the "speed and intelligence" tier of the current
  /// Claude line (models overview, checked 2026-11-09). Opus is slower and
  /// pricier than a chat contact needs; Haiku is the cheap override.
  static const anthropicModel = 'claude-sonnet-5-5';

  /// GPT-6.1 Sol: OpenAI's recommended balance of intelligence and cost
  /// (models catalog, checked 2026-11-09), supported on Chat Completions.
  /// Only a default for api.openai.com; other endpoints name their model.
  static const openaiModel = 'gpt-6.1-sol';

  /// Anthropic recommends `low`/`medium` effort for chat and other
  /// latency-sensitive work; Sonnet 5.5 defaults to `high` on the API.
  static const anthropicEffort = 'low';

  /// GPT-6.1 Sol supports `low` as its lowest `reasoning_effort`.
  static const openaiEffort = 'low';

  static const anthropicBaseUrl = 'https://api.anthropic.com';
  static const openaiBaseUrl = 'https://api.openai.com/v1';

  /// Thinking counts against `max_tokens` on current Claude models, so the
  /// cap leaves room for it and a long chat answer.
  static const maxTokens = 8192;
  static const historyMessages = 20;

  static String systemPrompt(String name) =>
      'You are $name, a friendly personal assistant inside the Jay '
      'messenger. Answer in the language the user writes in (often Czech). '
      'Be brief and clear; use simple formatting that reads well in a chat '
      'bubble (short paragraphs, plain lists, no tables). You can see '
      'images the user sends you.';
}

/// The settings of one provider of the chain (primary or fallback).
class ProviderSettings {
  const ProviderSettings({
    required this.kind,
    this.model,
    this.apiKey,
    this.baseUrl,
    this.effort,
    this.cliBinary,
    this.cliWorkDir,
  });

  final LlmProviderKind kind;
  final String? model;
  final String? apiKey;
  final String? baseUrl;
  final String? effort;
  final String? cliBinary;
  final String? cliWorkDir;

  bool get isCli =>
      kind == LlmProviderKind.claudeCli || kind == LlmProviderKind.codexCli;
}

final _handlePattern = RegExp(r'^CT-[A-Z0-9]{4}-[A-Z0-9]{4}$');

class LlmConfig {
  const LlmConfig({
    required this.apiUrl,
    required this.storePath,
    required this.allowedHandles,
    required this.displayName,
    required this.provider,
    required this.systemPrompt,
    this.model,
    this.apiKey,
    this.baseUrl,
    this.effort,
    this.maxTokens = LlmDefaults.maxTokens,
    this.historyMessages = LlmDefaults.historyMessages,
    this.timeout = const Duration(seconds: 300),
    this.progressAfter = const Duration(seconds: 5),
    this.cliBinary,
    this.cliWorkDir,
    this.fallbacks = const [],
    this.firstOutputTimeout = const Duration(seconds: 60),
    this.actions = const [],
    this.actionSteps = 3,
    this.actionTimeout = const Duration(seconds: 60),
    this.greeting = true,
    this.ackReactions = true,
    this.groupReplies = GroupReplies.members,
    this.inbound,
    this.peerTurnsCap = 50,
    this.imageModel,
    this.imageMaxBytes = defaultImageMaxBytes,
  });

  final String apiUrl;
  final String storePath;
  final Set<String> allowedHandles;
  final String displayName;
  final LlmProviderKind provider;

  /// Null = the provider's own default (CLI providers: the owner's CLI
  /// setting).
  final String? model;
  final String? apiKey;

  /// API base URL (HTTP providers).
  final String? baseUrl;

  /// Reasoning effort sent to the API; null = not sent.
  final String? effort;
  final int maxTokens;
  final int historyMessages;
  final String systemPrompt;
  final Duration timeout;

  /// "Working on it..." appears when no full answer came after this long;
  /// zero = never.
  final Duration progressAfter;

  /// `claude` / `codex` executable (CLI providers).
  final String? cliBinary;

  /// Empty working directory the CLI runs in (CLI providers).
  final String? cliWorkDir;

  /// `LLM_FALLBACK`: providers tried in order after [provider] (spec F1).
  final List<ProviderSettings> fallbacks;

  /// `LLM_FIRST_OUTPUT_SECONDS`: each attempt's time to its first text
  /// piece (spec F11); zero = no limit.
  final Duration firstOutputTimeout;

  /// `LLM_ACTIONS`: named commands the model may ask the bridge to run
  /// (spec A1); empty = none.
  final List<BridgeAction> actions;

  /// `LLM_ACTION_STEPS`: action rounds per user message (spec A2).
  final int actionSteps;

  /// `LLM_ACTION_SECONDS`: one action's time limit (spec A2).
  final Duration actionTimeout;

  /// The primary provider's settings ([provider], [model], ...).
  ProviderSettings get primary => ProviderSettings(
    kind: provider,
    model: model,
    apiKey: apiKey,
    baseUrl: baseUrl,
    effort: effort,
    cliBinary: cliBinary,
    cliWorkDir: cliWorkDir,
  );

  /// Send the one-time "Ahoj, jsem ..." greeting to the owners.
  final bool greeting;

  /// `ACK_REACTIONS`: 👀 on accepted messages, then the turn's final emoji
  /// (spec 2026-11-11-bot-ack-reactions).
  final bool ackReactions;

  /// `GROUP_REPLIES`: who besides the owners is answered in groups.
  final GroupReplies groupReplies;

  /// `BOT_INBOUND` as given (`owners` default, `open`), see
  /// `publishInboundPolicy`.
  final String? inbound;

  /// `PEER_MAX_TURNS_CAP`: ceiling for a bot-only exchange in a group.
  final int peerTurnsCap;

  /// `LLM_IMAGE_MODEL`: image generation model (provider openai only, spec
  /// 2026-11-10-bot-media M8); null = no image generation.
  final String? imageModel;

  /// `LLM_IMAGE_MAX_BYTES`: largest received image passed to the model.
  final int imageMaxBytes;

  /// Generated images wait here until they are sent (then deleted).
  String get mediaDir => '$storePath.media';

  /// The path of the encrypted history/greeting store next to the identity.
  String get statePath => '$storePath.llm';

  /// Reads the environment; throws [ConfigException] on anything unusable.
  ///
  /// WHY refuse to start on an empty `ALLOWED_HANDLES` (like a2a_bridge):
  /// every message costs the owner money or subscription quota and the
  /// conversation is private; a bot that answers nobody looks like a bug,
  /// a bot that answers everybody is a leak. A clear refusal is safer.
  static LlmConfig fromEnvironment(Map<String, String> env) {
    String? opt(String name) {
      final v = env[name]?.trim() ?? '';
      return v.isEmpty ? null : v;
    }

    String required(String name, [String? hint]) =>
        opt(name) ??
        (throw ConfigException(
          'Missing required environment variable $name.'
          '${hint == null ? '' : ' $hint'}',
        ));

    int positive(String name, int fallback, {int min = 1}) {
      final raw = opt(name);
      if (raw == null) return fallback;
      final v = int.tryParse(raw);
      if (v == null || v < min) {
        throw ConfigException('$name must be an integer >= $min, got "$raw".');
      }
      return v;
    }

    String httpUrl(String name, String value) {
      final u = Uri.tryParse(value);
      if (u == null ||
          !(u.scheme == 'http' || u.scheme == 'https') ||
          u.host.isEmpty) {
        throw ConfigException('$name must be an http(s) URL, got "$value".');
      }
      return value.endsWith('/') ? value.substring(0, value.length - 1) : value;
    }

    final providerRaw = required(
      'LLM_PROVIDER',
      'Use one of: ${LlmProviderKind.values.map((k) => k.id).join(', ')}.',
    );
    final provider =
        LlmProviderKind.parse(providerRaw) ??
        (throw ConfigException(
          'LLM_PROVIDER "$providerRaw" is unknown. Use one of: '
          '${LlmProviderKind.values.map((k) => k.id).join(', ')}.',
        ));

    final storePath = opt('BOT_STORE_PATH') ?? '/data/bot.store';
    final displayName = opt('BOT_DISPLAY_NAME') ?? 'Jay bot';
    final effortRaw = env['LLM_EFFORT']?.trim();
    // `LLM_EFFORT=none` (or `off`) sends no effort at all: for endpoints
    // that reject the field.
    String? effort(String? fallback) => effortRaw == null || effortRaw.isEmpty
        ? fallback
        : (effortRaw == 'none' || effortRaw == 'off' ? null : effortRaw);

    // One provider's settings, the same for the primary and every fallback
    // (spec F2): a fallback that could not start fails now, not at the
    // first failover. Model and effort are the primary's only (F3): model
    // ids differ per vendor, so fallbacks take their provider default.
    ProviderSettings settingsFor(
      LlmProviderKind kind, {
      required bool primary,
    }) {
      final where = primary ? '' : ' (needed by LLM_FALLBACK=${kind.id})';
      String? model = primary ? opt('LLM_MODEL') : null;
      String? effortOf(String? fallback) =>
          primary ? effort(fallback) : fallback;
      switch (kind) {
        case LlmProviderKind.anthropic:
          return ProviderSettings(
            kind: kind,
            apiKey: required(
              'ANTHROPIC_API_KEY',
              'Create one at https://platform.claude.com (API keys).$where',
            ),
            baseUrl: httpUrl(
              'ANTHROPIC_BASE_URL',
              opt('ANTHROPIC_BASE_URL') ?? LlmDefaults.anthropicBaseUrl,
            ),
            model: model ?? LlmDefaults.anthropicModel,
            effort: effortOf(LlmDefaults.anthropicEffort),
          );
        case LlmProviderKind.openai:
          final baseUrl = httpUrl(
            'OPENAI_BASE_URL',
            opt('OPENAI_BASE_URL') ?? LlmDefaults.openaiBaseUrl,
          );
          final official = Uri.parse(baseUrl).host == 'api.openai.com';
          final apiKey = opt('OPENAI_API_KEY');
          // WHY the key is optional off api.openai.com: local servers
          // (Ollama, LM Studio) take none; OpenAI itself always needs one.
          if (official && apiKey == null) {
            throw ConfigException(
              'Missing required environment variable OPENAI_API_KEY. Create '
              'one at https://platform.openai.com/api-keys, or set '
              'OPENAI_BASE_URL to a compatible endpoint.$where',
            );
          }
          if (model == null) {
            if (!official) {
              throw ConfigException(
                primary
                    ? 'LLM_MODEL is required with a custom OPENAI_BASE_URL '
                          '(the endpoint decides which models exist).'
                    : 'LLM_FALLBACK=openai with a custom OPENAI_BASE_URL is '
                          'not supported: fallbacks use their provider\'s '
                          'default model, and that endpoint has none '
                          '(LLM_MODEL is for LLM_PROVIDER only).',
              );
            }
            model = LlmDefaults.openaiModel;
          }
          return ProviderSettings(
            kind: kind,
            apiKey: apiKey,
            baseUrl: baseUrl,
            model: model,
            // Compatible servers differ in which reasoning fields they
            // accept; only OpenAI itself gets one by default.
            effort: effortOf(official ? LlmDefaults.openaiEffort : null),
          );
        case LlmProviderKind.claudeCli:
          return ProviderSettings(
            kind: kind,
            model: model,
            cliBinary: opt('CLAUDE_BIN') ?? 'claude',
            cliWorkDir: opt('LLM_CLI_WORKDIR') ?? '$storePath.cli',
          );
        case LlmProviderKind.codexCli:
          return ProviderSettings(
            kind: kind,
            model: model,
            cliBinary: opt('CODEX_BIN') ?? 'codex',
            cliWorkDir: opt('LLM_CLI_WORKDIR') ?? '$storePath.cli',
          );
      }
    }

    final primary = settingsFor(provider, primary: true);
    final fallbacks = <ProviderSettings>[];
    for (final part in (env['LLM_FALLBACK'] ?? '').split(',')) {
      final raw = part.trim();
      if (raw.isEmpty) continue;
      final kind =
          LlmProviderKind.parse(raw) ??
          (throw ConfigException(
            'LLM_FALLBACK: "$raw" is unknown. Use provider ids like '
            'LLM_PROVIDER: ${LlmProviderKind.values.map((k) => k.id).join(', ')}.',
          ));
      if (kind == provider) {
        throw ConfigException(
          'LLM_FALLBACK: ${kind.id} is already LLM_PROVIDER; list only the '
          'providers to try after it.',
        );
      }
      if (fallbacks.any((f) => f.kind == kind)) {
        throw ConfigException('LLM_FALLBACK: ${kind.id} is listed twice.');
      }
      fallbacks.add(settingsFor(kind, primary: false));
    }

    final imageModel = opt('LLM_IMAGE_MODEL');
    if (imageModel != null && provider != LlmProviderKind.openai) {
      throw ConfigException(
        'LLM_IMAGE_MODEL works only with LLM_PROVIDER=openai (the OpenAI '
        'Images API); ${provider.id} cannot create images. Remove it.',
      );
    }
    final imageMaxBytes = positive(
      'LLM_IMAGE_MAX_BYTES',
      defaultImageMaxBytes,
      min: 1024,
    );
    if (imageMaxBytes > imageMaxBytesCeiling) {
      throw ConfigException(
        'LLM_IMAGE_MAX_BYTES must be at most $imageMaxBytesCeiling '
        '(20 MB), got $imageMaxBytes.',
      );
    }

    final greetingRaw = (opt('BOT_GREETING') ?? 'on').toLowerCase();
    if (!const {'on', 'off', 'true', 'false', '1', '0'}.contains(greetingRaw)) {
      throw ConfigException(
        'BOT_GREETING must be on or off, got "$greetingRaw".',
      );
    }

    final ackRaw = (opt('ACK_REACTIONS') ?? 'on').toLowerCase();
    if (!const {'on', 'off', 'true', 'false', '1', '0'}.contains(ackRaw)) {
      throw ConfigException('ACK_REACTIONS must be on or off, got "$ackRaw".');
    }

    // WHY the CLI providers default to owners: they run on the owner's
    // personal subscription, which the vendors' terms cover for his own use
    // (README "Subscription providers"). Answering other group members is
    // an explicit opt-in there; API keys default to members (bot-access A4).
    // F8: any CLI provider in the chain counts, not only the primary.
    final cli = primary.isCli || fallbacks.any((f) => f.isCli);
    final groupRepliesRaw =
        opt('GROUP_REPLIES') ?? (cli ? 'owners' : 'members');
    final groupReplies =
        GroupReplies.parse(groupRepliesRaw) ??
        (throw ConfigException(
          'GROUP_REPLIES must be members or owners, got "$groupRepliesRaw".',
        ));
    final inbound = opt('BOT_INBOUND');
    if (inbound != null &&
        !const {'open', 'owners'}.contains(inbound.toLowerCase())) {
      throw ConfigException(
        'BOT_INBOUND must be owners or open, got "$inbound".',
      );
    }

    return LlmConfig(
      apiUrl: httpUrl('CALLTYPE_API_URL', required('CALLTYPE_API_URL')),
      storePath: storePath,
      allowedHandles: parseAllowedHandles(env['ALLOWED_HANDLES']),
      displayName: displayName,
      provider: provider,
      model: primary.model,
      apiKey: primary.apiKey,
      baseUrl: primary.baseUrl,
      effort: primary.effort,
      maxTokens: positive('LLM_MAX_TOKENS', LlmDefaults.maxTokens, min: 16),
      historyMessages: positive(
        'LLM_HISTORY_MESSAGES',
        LlmDefaults.historyMessages,
        min: 0,
      ),
      systemPrompt:
          opt('LLM_SYSTEM_PROMPT') ?? LlmDefaults.systemPrompt(displayName),
      timeout: Duration(seconds: positive('LLM_TIMEOUT_SECONDS', 300)),
      progressAfter: Duration(
        seconds: positive('PROGRESS_AFTER_SECONDS', 5, min: 0),
      ),
      cliBinary: primary.cliBinary,
      cliWorkDir: primary.cliWorkDir,
      fallbacks: fallbacks,
      firstOutputTimeout: Duration(
        seconds: positive('LLM_FIRST_OUTPUT_SECONDS', 60, min: 0),
      ),
      actions: parseActions(env['LLM_ACTIONS']),
      actionSteps: positive('LLM_ACTION_STEPS', 3),
      actionTimeout: Duration(seconds: positive('LLM_ACTION_SECONDS', 60)),
      greeting: const {'on', 'true', '1'}.contains(greetingRaw),
      ackReactions: const {'on', 'true', '1'}.contains(ackRaw),
      groupReplies: groupReplies,
      inbound: inbound,
      peerTurnsCap: positive('PEER_MAX_TURNS_CAP', 50, min: 0),
      imageModel: imageModel,
      imageMaxBytes: imageMaxBytes,
    );
  }
}

/// `ALLOWED_HANDLES` -> upper-case handle set. Throws when empty or when an
/// entry is not a `CT-XXXX-XXXX` handle (a typo must not silently shrink
/// the list to "nobody" or, worse, be mistaken for someone else).
Set<String> parseAllowedHandles(String? raw) {
  final handles = <String>{};
  for (final part in (raw ?? '').split(',')) {
    final h = part.trim().toUpperCase();
    if (h.isEmpty) continue;
    if (!_handlePattern.hasMatch(h)) {
      throw ConfigException(
        'ALLOWED_HANDLES: "$h" is not a Jay handle (CT-XXXX-XXXX).',
      );
    }
    handles.add(h);
  }
  if (handles.isEmpty) {
    throw const ConfigException(
      'ALLOWED_HANDLES is empty: refusing to start. Set it to your own Jay '
      'handle(s), e.g. ALLOWED_HANDLES=CT-XXXX-XXXX (Jay: Settings -> Identity).',
    );
  }
  return handles;
}

/// Resolves handles to device ids once at start (incoming messages carry
/// ids, not handles). Unknown handles are logged and skipped; if NONE
/// resolves the start is refused, same fail-closed rule as an empty list.
Future<Map<String, String>> resolveAllowedHandles(
  Set<String> handles,
  Future<String?> Function(String handle) lookup, {
  void Function(String) log = _noLog,
}) async {
  final ids = <String, String>{}; // device id (lower-case) -> handle
  for (final handle in handles) {
    final id = await lookup(handle);
    if (id == null) {
      log('ALLOWED_HANDLES: $handle is unknown to the server, ignored.');
    } else {
      ids[id.toLowerCase()] = handle;
    }
  }
  if (ids.isEmpty) {
    throw const ConfigException(
      'ALLOWED_HANDLES: none of the handles is known to the server; refusing '
      'to start (the bot would answer nobody).',
    );
  }
  return ids;
}

void _noLog(String _) {}
