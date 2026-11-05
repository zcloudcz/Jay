import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:a2a_bridge/a2a_bridge.dart';

/// One JSON-RPC request the fake agent received.
class RpcCall {
  RpcCall(this.method, this.params, this.headers, this.path);
  final String method;
  final Map<String, dynamic> params;
  final HttpHeaders headers;
  final String path;

  Map<String, dynamic> get message => params['message'] as Map<String, dynamic>;
}

/// What the fake answers: an HTTP status and a JSON body.
class FakeReply {
  const FakeReply(this.status, this.body);
  final int status;
  final Object? body;
}

FakeReply ok(Object? result) =>
    FakeReply(200, {'jsonrpc': '2.0', 'id': 1, 'result': result});

FakeReply rpcError(int code, [String message = 'error']) => FakeReply(200, {
  'jsonrpc': '2.0',
  'id': 1,
  'error': {'code': code, 'message': message},
});

/// A real HTTP server on loopback speaking just enough A2A for the tests.
class FakeA2aServer {
  FakeA2aServer._(this._server) {
    _server.listen(_serve);
  }

  static Future<FakeA2aServer> start() async =>
      FakeA2aServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;

  String get url => 'http://127.0.0.1:${_server.port}';

  /// Card path (e.g. `/.well-known/agent-card.json`) -> JSON. Unlisted = 404.
  final cards = <String, Object?>{};
  final cardRequests = <({String path, HttpHeaders headers})>[];
  final calls = <RpcCall>[];

  /// Answers every JSON-RPC POST. Default: method not found.
  FutureOr<FakeReply> Function(RpcCall call) onRpc = (_) => rpcError(-32601);

  Future<void> _serve(HttpRequest request) async {
    final path = request.uri.path;
    if (request.method == 'GET') {
      cardRequests.add((path: path, headers: request.headers));
      final card = cards[path];
      await _write(
        request.response,
        card == null
            ? const FakeReply(404, {'error': 'not found'})
            : FakeReply(200, card),
      );
      return;
    }
    final body =
        jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;
    final call = RpcCall(
      body['method'] as String,
      (body['params'] as Map).cast<String, dynamic>(),
      request.headers,
      path,
    );
    calls.add(call);
    await _write(request.response, await onRpc(call));
  }

  Future<void> _write(HttpResponse response, FakeReply reply) async {
    // The client may have aborted (timeout tests): writing then fails, and
    // that must not surface as an unhandled error in a later test.
    try {
      response.statusCode = reply.status;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(reply.body));
      await response.close();
    } catch (_) {}
  }

  Future<void> close() => _server.close(force: true);
}

/// A v1.0 card pointing at [endpoint].
Map<String, dynamic> v1Card(
  String endpoint, {
  List<Map<String, dynamic>> skills = const [],
}) => {
  'name': 'Test Agent',
  'description': 'A fake agent',
  'url': endpoint,
  'version': '1.0.0',
  'supportedInterfaces': [
    {'url': endpoint, 'protocolBinding': 'JSONRPC', 'protocolVersion': '1.0'},
  ],
  'capabilities': {'streaming': false},
  'skills': skills,
};

/// A v0.3 card pointing at [endpoint].
Map<String, dynamic> v03Card(String endpoint) => {
  'name': 'Old Agent',
  'description': 'v0.3',
  'protocolVersion': '0.3.0',
  'url': endpoint,
  'preferredTransport': 'JSONRPC',
  'skills': [
    {'id': 'summarize', 'name': 'Summarize', 'description': 'Summaries'},
  ],
};

/// A v1.0 task exactly as Hermes' A2A plugin builds it (answer in both
/// status.message and an artifact).
Map<String, dynamic> v1Task(
  String id,
  String state, {
  String? text,
  String contextId = 'ctx-1',
  bool artifact = true,
}) => {
  'id': id,
  'contextId': contextId,
  'status': {
    'state': state,
    'timestamp': '2026-11-05T10:00:00.000Z',
    if (text != null)
      'message': {
        'role': 'ROLE_AGENT',
        'parts': [
          {'text': text, 'mediaType': 'text/plain'},
        ],
        'messageId': 'm-$id',
        'contextId': contextId,
      },
  },
  if (text != null && artifact && state == 'TASK_STATE_COMPLETED')
    'artifacts': [
      {
        'artifactId': 'a-$id',
        'parts': [
          {'text': text, 'mediaType': 'text/plain'},
        ],
      },
    ],
};

/// Records what the bridge writes into the chat.
class FakeSink implements ChatSink {
  final events = <String>[];

  @override
  Future<ProgressHandle> progress(String text) async {
    events.add('progress:$text');
    return _FakeProgress(events);
  }

  @override
  Future<void> reply(String text) async => events.add('reply:$text');
}

class _FakeProgress implements ProgressHandle {
  _FakeProgress(this.events);
  final List<String> events;
  @override
  Future<void> update(String text) async => events.add('edit:$text');
}
