import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One message of a conversation as the provider sees it.
class ChatTurn {
  const ChatTurn.user(this.text) : role = 'user';
  const ChatTurn.assistant(this.text) : role = 'assistant';

  /// `user` or `assistant` (the wire names of both APIs).
  final String role;
  final String text;

  Map<String, String> toJson() => {'role': role, 'text': text};

  static ChatTurn? fromJson(Object? json) {
    if (json is! Map) return null;
    final text = json['text'];
    if (text is! String) return null;
    return switch (json['role']) {
      'user' => ChatTurn.user(text),
      'assistant' => ChatTurn.assistant(text),
      _ => null,
    };
  }

  @override
  bool operator ==(Object other) =>
      other is ChatTurn && other.role == role && other.text == text;

  @override
  int get hashCode => Object.hash(role, text);

  @override
  String toString() => '$role: $text';
}

/// A provider failed. [message] is safe to show to the owner: it never
/// contains the API key or the request.
class LlmException implements Exception {
  const LlmException(this.message, {this.status, this.retryAfter});
  final String message;

  /// HTTP status, when the failure was an HTTP answer.
  final int? status;

  /// The server's `retry-after`, when it sent one.
  final Duration? retryAfter;

  bool get isRateLimit => status == 429;
  bool get isAuth => status == 401 || status == 403;

  @override
  String toString() => status == null
      ? 'LlmException: $message'
      : 'LlmException($status): $message';
}

/// Where answers come from. One [reply] call per incoming message.
abstract class LlmProvider {
  /// A short name for logs and `/help` ("Anthropic claude-sonnet-5-5").
  String get label;

  /// Answers the last (user) turn of [conversation], given [system] as the
  /// system prompt. Emits text pieces in order; providers that cannot
  /// stream emit the whole answer once. Errors are [LlmException]s.
  ///
  /// Cancelling the subscription aborts the request or kills the process.
  Stream<String> reply(List<ChatTurn> conversation, {required String system});

  Future<void> close();
}

/// One server-sent event.
class SseEvent {
  const SseEvent(this.event, this.data);
  final String? event;
  final String data;
}

/// Parses a `text/event-stream` body (WHATWG rules that matter here:
/// `event:`/`data:` fields, multi-line data joined by `\n`, blank line ends
/// an event, `:` comments ignored).
Stream<SseEvent> parseSse(Stream<List<int>> bytes) async* {
  String? event;
  final data = <String>[];
  await for (final raw
      in bytes
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
    if (raw.isEmpty) {
      if (data.isNotEmpty) yield SseEvent(event, data.join('\n'));
      event = null;
      data.clear();
      continue;
    }
    if (raw.startsWith(':')) continue;
    final colon = raw.indexOf(':');
    final field = colon < 0 ? raw : raw.substring(0, colon);
    var value = colon < 0 ? '' : raw.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    if (field == 'event') event = value;
    if (field == 'data') data.add(value);
  }
  if (data.isNotEmpty) yield SseEvent(event, data.join('\n'));
}

/// Shared plumbing of the two HTTP providers.
///
/// WHY dart:io instead of package:http or dio: two POSTs with SSE bodies do
/// not justify another dependency in a bundle that strangers download.
abstract class HttpLlmProvider implements LlmProvider {
  HttpLlmProvider({HttpClient? client})
    : _client =
          client ??
          (HttpClient()..connectionTimeout = const Duration(seconds: 20));

  final HttpClient _client;

  /// POSTs [body] as JSON and returns the response, or throws
  /// [LlmException] for a non-2xx answer (with the provider's error text).
  Future<HttpClientResponse> postJson(
    Uri url,
    Map<String, String> headers,
    Object body,
  ) async {
    final HttpClientResponse response;
    try {
      final request = await _client.postUrl(url);
      request.headers.contentType = ContentType.json;
      headers.forEach(request.headers.set);
      request.add(utf8.encode(jsonEncode(body)));
      response = await request.close();
    } on SocketException catch (e) {
      throw LlmException('cannot reach ${url.host} (${e.message})');
    } on HandshakeException catch (e) {
      throw LlmException('TLS error with ${url.host} (${e.message})');
    } on HttpException catch (e) {
      throw LlmException('HTTP error with ${url.host} (${e.message})');
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response;
    }
    final text = await _readSmall(response);
    throw LlmException(
      _errorMessage(text) ?? 'HTTP ${response.statusCode}',
      status: response.statusCode,
      retryAfter: _retryAfter(response.headers.value('retry-after')),
    );
  }

  static Future<String> _readSmall(HttpClientResponse response) async {
    final out = BytesBuilder(copy: false);
    await for (final chunk in response) {
      out.add(chunk);
      if (out.length > 64 * 1024) break;
    }
    return utf8.decode(out.takeBytes(), allowMalformed: true);
  }

  /// `{"error":{"message":...}}` (both vendors) or `{"error":"..."}`
  /// (several compatible servers).
  static String? _errorMessage(String body) {
    try {
      final json = jsonDecode(body);
      if (json is Map) {
        final error = json['error'];
        if (error is Map && error['message'] is String) {
          return error['message'] as String;
        }
        if (error is String) return error;
        if (json['message'] is String) return json['message'] as String;
      }
    } on FormatException {
      // Not JSON (a proxy's HTML page): the status says enough.
    }
    return null;
  }

  static Duration? _retryAfter(String? raw) {
    final seconds = int.tryParse(raw?.trim() ?? '');
    return seconds == null || seconds < 0 ? null : Duration(seconds: seconds);
  }

  @override
  Future<void> close() async => _client.close(force: true);
}
