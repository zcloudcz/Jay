import 'cli_providers.dart';
import 'config.dart';
import 'http_providers.dart';
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
