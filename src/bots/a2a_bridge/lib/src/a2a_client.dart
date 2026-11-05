import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'a2a_protocol.dart';

/// Any failure talking to the agent. [httpStatus] / [rpcCode] tell the
/// bridge which short user message fits.
class A2aException implements Exception {
  const A2aException(this.message, {this.httpStatus, this.rpcCode});
  final String message;
  final int? httpStatus;
  final int? rpcCode;

  /// The agent refused our credentials (or wants some we do not have).
  bool get isAuth => httpStatus == 401 || httpStatus == 403;

  /// Worth another try later (polling): overload or a proxy hiccup.
  bool get isTransient =>
      httpStatus != null && (httpStatus! >= 500 || httpStatus == 429);

  @override
  String toString() => 'A2aException: $message';
}

/// Misconfiguration found while connecting (bad card, unsafe endpoint).
class A2aConfigException implements Exception {
  const A2aConfigException(this.message);
  final String message;
  @override
  String toString() => 'A2aConfigException: $message';
}

/// JSON-RPC "method not found": the trigger for the version fallback.
const rpcMethodNotFound = -32601;

/// Minimal A2A JSON-RPC client: card discovery, send, get task.
///
/// Deliberately no streaming (`SendStreamingMessage`): blocking send plus
/// GetTask polling works with every server, needs no SSE parser, and the
/// chat only shows a throttled progress message anyway.
class A2aClient {
  A2aClient({
    required String agentUrl,
    this.token,
    String? endpointOverride,
    HttpClient? http,
    this.log = _noLog,
  }) : agentUri = _withoutTrailingSlash(Uri.parse(agentUrl)),
       _endpointOverride = endpointOverride == null || endpointOverride.isEmpty
           ? null
           : Uri.parse(endpointOverride),
       _http = http ?? HttpClient();

  static void _noLog(String _) {}

  final Uri agentUri;
  final String? token;
  final Uri? _endpointOverride;
  final HttpClient _http;
  final void Function(String) log;

  Uri? _endpoint;
  String? _tenant;

  /// Starts as the card's guess; flips (and stays) after a `-32601`.
  A2aVersion version = A2aVersion.v1;
  var _nextId = 1;

  /// WHY a cap: a misbehaving or hostile agent must not make the bridge
  /// buffer gigabytes. Chat replies are a few KiB.
  static const maxResponseBytes = 4 * 1024 * 1024;

  /// The JSON-RPC endpoint in use (after [discover]).
  Uri get endpoint => _endpoint ?? _endpointOverride ?? agentUri;

  static Uri _withoutTrailingSlash(Uri u) {
    var path = u.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return u.replace(path: path);
  }

  static bool _sameOrigin(Uri a, Uri b) =>
      a.scheme == b.scheme && a.host == b.host && a.port == b.port;

  /// Fetches the Agent Card (`/.well-known/agent-card.json`, then the
  /// pre-1.0 `/.well-known/agent.json`) and adopts its JSON-RPC endpoint.
  ///
  /// If `A2A_AGENT_URL` already ends in `.json` it is taken as the card URL.
  ///
  /// WHY the same-origin rule: the card is data from the agent, and the
  /// bridge attaches `A2A_TOKEN` to every RPC. A card naming another host
  /// would make the bridge hand its credential to that host. Behind a proxy
  /// whose public URL differs, the operator names the endpoint explicitly
  /// (`A2A_ENDPOINT_URL`), which is trusted because it comes from config.
  Future<AgentCard> discover({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final candidates = agentUri.path.endsWith('.json')
        ? [agentUri]
        : [
            agentUri.replace(
              path: '${agentUri.path}/.well-known/agent-card.json',
            ),
            agentUri.replace(path: '${agentUri.path}/.well-known/agent.json'),
          ];
    final failures = <String>[];
    for (final uri in candidates) {
      final ({int status, Object? json}) response;
      try {
        response = await _request('GET', uri, null, timeout: timeout);
      } on TimeoutException {
        failures.add('$uri: timeout');
        continue;
      } on IOException catch (e) {
        failures.add('$uri: $e');
        continue;
      }
      if (response.status == 401 || response.status == 403) {
        throw A2aException(
          'Agent card $uri: HTTP ${response.status} (check A2A_TOKEN)',
          httpStatus: response.status,
        );
      }
      final json = response.json;
      if (response.status != 200 || json is! Map<String, dynamic>) {
        failures.add('$uri: HTTP ${response.status}');
        continue;
      }
      final AgentCard card;
      try {
        card = parseAgentCard(json, uri);
      } on AgentCardException catch (e) {
        throw A2aConfigException(e.message);
      }
      _adopt(card);
      return card;
    }
    throw A2aException('No agent card found (${failures.join('; ')})');
  }

  void _adopt(AgentCard card) {
    version = card.preferredVersion;
    _tenant = card.tenant;
    final override = _endpointOverride;
    if (override != null) {
      _endpoint = override;
      return;
    }
    final fromCard = card.endpoint ?? agentUri;
    if (!_sameOrigin(fromCard, agentUri)) {
      throw A2aConfigException(
        'The agent card names endpoint $fromCard, a different origin than '
        'A2A_AGENT_URL ($agentUri). Refusing to send the token there; set '
        'A2A_ENDPOINT_URL if that endpoint is really yours.',
      );
    }
    _endpoint = fromCard;
  }

  /// Sends [text] as a user message. [contextId] keeps the conversation,
  /// [taskId] continues an `input-required` task.
  Future<A2aResult> sendMessage(
    String text, {
    String? contextId,
    String? taskId,
    required Duration timeout,
  }) async {
    final messageId = _uuidV4();
    Future<Object?> call(A2aVersion v) =>
        _rpc(v, v == A2aVersion.v1 ? 'SendMessage' : 'message/send', {
          'message': buildUserMessage(
            v,
            messageId: messageId,
            text: text,
            contextId: contextId,
            taskId: taskId,
          ),
          // v1.0: an interface with a tenant requires it echoed in params.
          if (v == A2aVersion.v1 && _tenant != null) 'tenant': _tenant,
        }, timeout: timeout);
    final result = await _withFallback(call);
    final parsed = parseSendResult(result);
    if (parsed == null) {
      throw const A2aException(
        'The agent returned neither a message nor a task.',
      );
    }
    return parsed;
  }

  /// Current state of task [id] (`GetTask` / `tasks/get`).
  Future<A2aTask> getTask(String id, {required Duration timeout}) async {
    final result = await _withFallback(
      (v) => _rpc(v, v == A2aVersion.v1 ? 'GetTask' : 'tasks/get', {
        'id': id,
        if (v == A2aVersion.v1 && _tenant != null) 'tenant': _tenant,
      }, timeout: timeout),
    );
    if (result is! Map) {
      throw const A2aException('GetTask returned no task.');
    }
    return parseTask(result);
  }

  /// Runs [call] with the current [version]; on `-32601` once more with the
  /// other one, which then sticks.
  ///
  /// WHY resending is safe: "method not found" means the server did not run
  /// anything, so the message cannot arrive twice.
  Future<Object?> _withFallback(
    Future<Object?> Function(A2aVersion) call,
  ) async {
    try {
      return await call(version);
    } on A2aException catch (e) {
      if (e.rpcCode != rpcMethodNotFound) rethrow;
      final other = version == A2aVersion.v1 ? A2aVersion.v03 : A2aVersion.v1;
      log(
        'A2A: method not found with ${version.name}, retrying with ${other.name}.',
      );
      final result = await call(other);
      version = other;
      return result;
    }
  }

  Future<Object?> _rpc(
    A2aVersion v,
    String method,
    Map<String, dynamic> params, {
    required Duration timeout,
  }) async {
    final id = _nextId++;
    final response = await _request(
      'POST',
      endpoint,
      {'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params},
      timeout: timeout,
      // v1.0: clients MUST send it; an empty header means 0.3 by spec.
      a2aVersion: v == A2aVersion.v1 ? '1.0' : null,
    );
    final json = response.json;
    // WHY auth before the JSON-RPC error: servers answer 401 with a JSON-RPC
    // error body too, and "check A2A_TOKEN" is the actionable part.
    if (response.status == 401 || response.status == 403) {
      throw A2aException(
        '$method: HTTP ${response.status}',
        httpStatus: response.status,
      );
    }
    if (json is Map && json['error'] is Map) {
      final error = json['error'] as Map;
      final code = error['code'];
      throw A2aException(
        '$method: ${error['message'] ?? 'error'} (code $code)',
        rpcCode: code is int ? code : null,
        httpStatus: response.status == 200 ? null : response.status,
      );
    }
    if (response.status != 200) {
      throw A2aException(
        '$method: HTTP ${response.status}',
        httpStatus: response.status,
      );
    }
    if (json is! Map || !json.containsKey('result')) {
      throw A2aException('$method: response is not JSON-RPC');
    }
    return json['result'];
  }

  Future<({int status, Object? json})> _request(
    String method,
    Uri uri,
    Object? body, {
    required Duration timeout,
    String? a2aVersion,
  }) async {
    HttpClientRequest? request;
    // WHY abort instead of only a Future timeout: an abandoned request would
    // keep its socket open until the agent finally answers.
    final timer = Timer(timeout, () => request?.abort(TimeoutException(null)));
    try {
      request = await _http.openUrl(method, uri).timeout(timeout);
      final t = token;
      if (t != null && t.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $t');
      }
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (a2aVersion != null) request.headers.set('A2A-Version', a2aVersion);
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.add(utf8.encode(jsonEncode(body)));
      }
      final response = await request.close().timeout(timeout);
      final bytes = <int>[];
      await for (final chunk in response.timeout(timeout)) {
        bytes.addAll(chunk);
        if (bytes.length > maxResponseBytes) {
          throw A2aException('Response larger than $maxResponseBytes bytes');
        }
      }
      Object? json;
      try {
        json = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      } on FormatException {
        // A proxy's HTML error page: the status code is all we can use.
      }
      return (status: response.statusCode, json: json);
    } on HttpException catch (e) {
      // abort() surfaces as HttpException wrapping our TimeoutException.
      if (!timer.isActive) throw TimeoutException(e.message, timeout);
      rethrow;
    } finally {
      timer.cancel();
    }
  }

  void close() => _http.close(force: true);

  static final _random = Random.secure();

  static String _uuidV4() {
    final b = List<int>.generate(16, (_) => _random.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20)}';
  }
}
