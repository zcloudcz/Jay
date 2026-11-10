import 'cli_providers.dart';
import 'config.dart';
import 'http_providers.dart';
import 'images.dart';
import 'provider.dart';

/// The provider [config] asks for.
LlmProvider buildProvider(LlmConfig config) => switch (config.provider) {
  LlmProviderKind.anthropic => AnthropicProvider(
    apiKey: config.apiKey!,
    model: config.model!,
    baseUrl: config.baseUrl!,
    maxTokens: config.maxTokens,
    effort: config.effort,
  ),
  LlmProviderKind.openai => OpenAiProvider(
    apiKey: config.apiKey,
    model: config.model!,
    baseUrl: config.baseUrl!,
    maxTokens: config.maxTokens,
    effort: config.effort,
  ),
  LlmProviderKind.claudeCli => ClaudeCliProvider(
    executable: config.cliBinary!,
    workDir: config.cliWorkDir!,
    model: config.model,
  ),
  LlmProviderKind.codexCli => CodexCliProvider(
    executable: config.cliBinary!,
    workDir: config.cliWorkDir!,
    model: config.model,
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
