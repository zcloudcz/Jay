import 'cli_providers.dart';
import 'config.dart';
import 'fallback.dart';
import 'http_providers.dart';
import 'images.dart';
import 'provider.dart';

/// The provider [config] asks for: the primary alone, or the chain with
/// `LLM_FALLBACK` (spec F1), each attempt under the first-output limit
/// (F11; zero = none).
LlmProvider buildProvider(
  LlmConfig config, {
  void Function(String) log = _noLog,
}) {
  LlmProvider guarded(ProviderSettings s) {
    final p = buildSingleProvider(s, maxTokens: config.maxTokens);
    return config.firstOutputTimeout > Duration.zero
        ? FirstOutputGuard(p, config.firstOutputTimeout)
        : p;
  }

  final primary = guarded(config.primary);
  if (config.fallbacks.isEmpty) return primary;
  return FallbackProvider([
    primary,
    for (final f in config.fallbacks) guarded(f),
  ], log: log);
}

void _noLog(String _) {}

/// One provider from its settings.
LlmProvider buildSingleProvider(
  ProviderSettings s, {
  int maxTokens = LlmDefaults.maxTokens,
}) => switch (s.kind) {
  LlmProviderKind.anthropic => AnthropicProvider(
    apiKey: s.apiKey!,
    model: s.model!,
    baseUrl: s.baseUrl!,
    maxTokens: maxTokens,
    effort: s.effort,
  ),
  LlmProviderKind.openai => OpenAiProvider(
    apiKey: s.apiKey,
    model: s.model!,
    baseUrl: s.baseUrl!,
    maxTokens: maxTokens,
    effort: s.effort,
  ),
  LlmProviderKind.claudeCli => ClaudeCliProvider(
    executable: s.cliBinary!,
    workDir: s.cliWorkDir!,
    model: s.model,
  ),
  LlmProviderKind.codexCli => CodexCliProvider(
    executable: s.cliBinary!,
    workDir: s.cliWorkDir!,
    model: s.model,
  ),
};

/// The image generator [config] opts into (`LLM_IMAGE_MODEL`, provider
/// openai only, spec 2026-11-10-bot-media M8), or null.
ImageGenerator? buildImageGenerator(LlmConfig config) {
  final model = config.imageModel;
  if (model == null || config.provider != LlmProviderKind.openai) return null;
  return OpenAiImageGenerator(
    model: model,
    apiKey: config.apiKey,
    baseUrl: config.baseUrl!,
  );
}
