import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One request the fake LLM server received.
class RecordedRequest {
  RecordedRequest(this.method, this.path, this.headers, this.body);
  final String method;
  final String path;
  final Map<String, String> headers;
  final Map<String, dynamic> body;
}

/// One scripted answer: status, headers, and body pieces written with a
/// small pause between them (so streaming is really incremental).
class FakeAnswer {
  FakeAnswer.sse(
    this.pieces, {
    this.status = 200,
    this.headers = const {},
    this.pause = Duration.zero,
  });
  FakeAnswer.json(Object body, {this.status = 200, this.headers = const {}})
    : pieces = [jsonEncode(body)],
      pause = Duration.zero;

  final int status;
  final Map<String, String> headers;
  final List<String> pieces;
  final Duration pause;
}

/// Loopback stand-in for api.anthropic.com / api.openai.com. Answers are
/// served in order; when they run out the last one repeats.
class FakeLlmServer {
  FakeLlmServer._(this._server);
  final HttpServer _server;
  final requests = <RecordedRequest>[];
  final answers = <FakeAnswer>[];

  String get url => 'http://127.0.0.1:${_server.port}';

  static Future<FakeLlmServer> start() async {
    final s = FakeLlmServer._(await HttpServer.bind('127.0.0.1', 0));
    s._server.listen(s._serve);
    return s;
  }

  Future<void> _serve(HttpRequest request) async {
    final headers = <String, String>{};
    request.headers.forEach((name, values) => headers[name] = values.join(','));
    final text = await utf8.decodeStream(request);
    requests.add(
      RecordedRequest(
        request.method,
        request.uri.path,
        headers,
        text.isEmpty ? {} : jsonDecode(text) as Map<String, dynamic>,
      ),
    );
    final answer = answers.length > 1 ? answers.removeAt(0) : answers.single;
    final response = request.response;
    response.statusCode = answer.status;
    answer.headers.forEach(response.headers.set);
    response.headers.contentType =
        answer.status == 200 && answer.pieces.length != 1
        ? ContentType('text', 'event-stream')
        : ContentType.json;
    for (final piece in answer.pieces) {
      response.add(utf8.encode(piece));
      await response.flush();
      if (answer.pause > Duration.zero) {
        await Future<void>.delayed(answer.pause);
      }
    }
    await response.close();
  }

  Future<void> close() => _server.close(force: true);
}

/// Anthropic SSE for [texts] as text deltas (with a thinking block first,
/// which the provider must skip).
List<String> anthropicStream(List<String> texts) => [
  'event: message_start\ndata: {"type":"message_start","message":{"id":"m1","role":"assistant","content":[]}}\n\n',
  'event: content_block_start\ndata: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}\n\n',
  'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}\n\n',
  'event: ping\ndata: {"type":"ping"}\n\n',
  for (final t in texts)
    'event: content_block_delta\ndata: ${jsonEncode({
      'type': 'content_block_delta',
      'index': 1,
      'delta': {'type': 'text_delta', 'text': t},
    })}\n\n',
  'event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}\n\n',
  'event: message_stop\ndata: {"type":"message_stop"}\n\n',
];

/// OpenAI Chat Completions SSE for [texts].
List<String> openAiStream(List<String> texts) => [
  'data: {"id":"c1","choices":[{"index":0,"delta":{"role":"assistant","content":""}}]}\n\n',
  for (final t in texts)
    'data: ${jsonEncode({
      'id': 'c1',
      'choices': [
        {
          'index': 0,
          'delta': {'content': t},
        },
      ],
    })}\n\n',
  'data: {"id":"c1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n',
  'data: [DONE]\n\n',
];
