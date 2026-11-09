import 'dart:async';
import 'dart:convert';

import 'provider.dart';

/// Merges consecutive turns of the same role and drops leading assistant
/// turns, so the list starts with `user` and alternates.
///
/// WHY: the Anthropic Messages API requires the first message to be from
/// the user, and a cut history (cap) or a failed earlier answer can leave
/// an assistant turn first or two user turns in a row.
List<ChatTurn> normalizeTurns(List<ChatTurn> turns) {
  final out = <ChatTurn>[];
  for (final t in turns) {
    if (t.text.trim().isEmpty) continue;
    if (out.isEmpty && t.role != 'user') continue;
    if (out.isNotEmpty && out.last.role == t.role) {
      final merged = '${out.last.text}\n\n${t.text}';
      out[out.length - 1] = t.role == 'user'
          ? ChatTurn.user(merged)
          : ChatTurn.assistant(merged);
    } else {
      out.add(t);
    }
  }
  return out;
}

/// Anthropic Messages API (`POST /v1/messages`, SSE streaming).
///
/// Wire shape per platform.claude.com/docs (checked 2026-11-09): headers
/// `x-api-key` + `anthropic-version: 2023-06-01`; body `model`,
/// `max_tokens`, `system`, `messages`, `stream: true`, optional
/// `output_config.effort`. Text arrives as `content_block_delta` events
/// with `delta.type == "text_delta"`; thinking deltas are skipped.
class AnthropicProvider extends HttpLlmProvider {
  AnthropicProvider({
    required this.apiKey,
    required this.model,
    this.baseUrl = 'https://api.anthropic.com',
    this.maxTokens = 8192,
    this.effort,
    super.client,
  });

  final String apiKey;
  final String model;
  final String baseUrl;
  final int maxTokens;
  final String? effort;

  @override
  String get label => 'Anthropic $model';

  /// The request body, public for tests.
  Map<String, Object?> requestBody(
    List<ChatTurn> conversation,
    String system,
  ) => {
    'model': model,
    'max_tokens': maxTokens,
    'system': system,
    'messages': [
      for (final t in normalizeTurns(conversation))
        {'role': t.role, 'content': t.text},
    ],
    'stream': true,
    if (effort != null) 'output_config': {'effort': effort},
  };

  @override
  Stream<String> reply(
    List<ChatTurn> conversation, {
    required String system,
  }) async* {
    final response = await postJson(Uri.parse('$baseUrl/v1/messages'), {
      'x-api-key': apiKey,
      'anthropic-version': '2023-06-01',
    }, requestBody(conversation, system));
    await for (final e in parseSse(response)) {
      final Object? json;
      try {
        json = jsonDecode(e.data);
      } on FormatException {
        continue;
      }
      if (json is! Map) continue;
      switch (json['type']) {
        case 'content_block_delta':
          final delta = json['delta'];
          if (delta is Map &&
              delta['type'] == 'text_delta' &&
              delta['text'] is String) {
            yield delta['text'] as String;
          }
        case 'error':
          // Mid-stream errors (e.g. overloaded_error) come as an SSE event
          // after a 200, so the status code cannot tell.
          final error = json['error'];
          final type = error is Map ? error['type'] : null;
          final message = error is Map ? error['message'] : null;
          throw LlmException(
            message is String ? message : 'stream error',
            status: type == 'overloaded_error'
                ? 529
                : (type == 'rate_limit_error' ? 429 : null),
          );
        case 'message_stop':
          return;
      }
    }
  }
}

/// OpenAI Chat Completions (`POST {base}/chat/completions`, SSE), which
/// every "OpenAI-compatible" server implements: OpenAI, Azure OpenAI v1,
/// OpenRouter, Ollama, LM Studio, vLLM.
///
/// WHY Chat Completions and not the Responses API: OpenAI's own models
/// support both (gpt-6.1-sol lists both endpoints), but most compatible
/// servers only implement Chat Completions, and this bot needs no tools.
class OpenAiProvider extends HttpLlmProvider {
  OpenAiProvider({
    required this.model,
    this.apiKey,
    this.baseUrl = 'https://api.openai.com/v1',
    this.maxTokens = 8192,
    this.effort,
    super.client,
  });

  final String model;
  final String? apiKey;
  final String baseUrl;
  final int maxTokens;
  final String? effort;

  bool get _official => Uri.parse(baseUrl).host == 'api.openai.com';
  bool get _azure => Uri.parse(baseUrl).host.endsWith('.azure.com');

  @override
  String get label => 'OpenAI-compatible $model';

  /// The request body, public for tests.
  Map<String, Object?> requestBody(
    List<ChatTurn> conversation,
    String system,
  ) => {
    'model': model,
    'messages': [
      {'role': 'system', 'content': system},
      for (final t in normalizeTurns(conversation))
        {'role': t.role, 'content': t.text},
    ],
    'stream': true,
    // OpenAI deprecated `max_tokens` for reasoning models in favour of
    // `max_completion_tokens`; many compatible servers only know the old
    // name, so each gets the one it understands.
    if (_official)
      'max_completion_tokens': maxTokens
    else
      'max_tokens': maxTokens,
    if (effort != null) 'reasoning_effort': effort,
  };

  @override
  Stream<String> reply(
    List<ChatTurn> conversation, {
    required String system,
  }) async* {
    final key = apiKey;
    final response = await postJson(Uri.parse('$baseUrl/chat/completions'), {
      if (key != null) 'authorization': 'Bearer $key',
      // Azure OpenAI authenticates API keys with its own header.
      if (key != null && _azure) 'api-key': key,
    }, requestBody(conversation, system));
    await for (final e in parseSse(response)) {
      if (e.data.trim() == '[DONE]') return;
      final Object? json;
      try {
        json = jsonDecode(e.data);
      } on FormatException {
        continue;
      }
      if (json is! Map) continue;
      final error = json['error'];
      if (error != null) {
        final message = error is Map ? error['message'] : error;
        throw LlmException(message is String ? message : 'stream error');
      }
      final choices = json['choices'];
      if (choices is! List || choices.isEmpty) continue;
      final first = choices.first;
      final delta = first is Map ? first['delta'] : null;
      final content = delta is Map ? delta['content'] : null;
      if (content is String && content.isNotEmpty) yield content;
    }
  }
}
