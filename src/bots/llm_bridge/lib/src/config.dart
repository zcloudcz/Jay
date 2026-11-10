/// Environment configuration of the LLM bridge, parsed in pure Dart so the
/// fail-closed rules are unit-tested.
library;

import 'access.dart' show GroupReplies;
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
    this.greeting = true,
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

  /// Send the one-time "Ahoj, jsem ..." greeting to the owners.
  final bool greeting;

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

    String? model = opt('LLM_MODEL');
    String? apiKey;
    String? baseUrl;
    String? effortValue;
    String? cliBinary;
    String? cliWorkDir;
    switch (provider) {
      case LlmProviderKind.anthropic:
        apiKey = required(
          'ANTHROPIC_API_KEY',
          'Create one at https://platform.claude.com (API keys).',
        );
        baseUrl = httpUrl(
          'ANTHROPIC_BASE_URL',
          opt('ANTHROPIC_BASE_URL') ?? LlmDefaults.anthropicBaseUrl,
        );
        model ??= LlmDefaults.anthropicModel;
        effortValue = effort(LlmDefaults.anthropicEffort);
      case LlmProviderKind.openai:
        baseUrl = httpUrl(
          'OPENAI_BASE_URL',
          opt('OPENAI_BASE_URL') ?? LlmDefaults.openaiBaseUrl,
        );
        final official = Uri.parse(baseUrl).host == 'api.openai.com';
        apiKey = opt('OPENAI_API_KEY');
        // WHY the key is optional off api.openai.com: local servers
        // (Ollama, LM Studio) take none; OpenAI itself always needs one.
        if (official && apiKey == null) {
          throw const ConfigException(
            'Missing required environment variable OPENAI_API_KEY. Create '
            'one at https://platform.openai.com/api-keys, or set '
            'OPENAI_BASE_URL to a compatible endpoint.',
          );
        }
        if (model == null) {
          if (!official) {
            throw const ConfigException(
              'LLM_MODEL is required with a custom OPENAI_BASE_URL (the '
              'endpoint decides which models exist).',
            );
          }
          model = LlmDefaults.openaiModel;
        }
        // Compatible servers differ in which reasoning fields they accept;
        // only OpenAI itself gets one by default.
        effortValue = effort(official ? LlmDefaults.openaiEffort : null);
      case LlmProviderKind.claudeCli:
        cliBinary = opt('CLAUDE_BIN') ?? 'claude';
        cliWorkDir = opt('LLM_CLI_WORKDIR') ?? '$storePath.cli';
      case LlmProviderKind.codexCli:
        cliBinary = opt('CODEX_BIN') ?? 'codex';
        cliWorkDir = opt('LLM_CLI_WORKDIR') ?? '$storePath.cli';
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

    // WHY the CLI providers default to owners: they run on the owner's
    // personal subscription, which the vendors' terms cover for his own use
    // (README "Subscription providers"). Answering other group members is
    // an explicit opt-in there; API keys default to members (bot-access A4).
    final cli =
        provider == LlmProviderKind.claudeCli ||
        provider == LlmProviderKind.codexCli;
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
      model: model,
      apiKey: apiKey,
      baseUrl: baseUrl,
      effort: effortValue,
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
      cliBinary: cliBinary,
      cliWorkDir: cliWorkDir,
      greeting: const {'on', 'true', '1'}.contains(greetingRaw),
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
