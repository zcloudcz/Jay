import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Result of a local send request, see [startSendEndpoint].
enum SendOutcome {
  sent,

  /// The bridge's rules do not allow this target (or it cannot be verified).
  forbidden,

  /// Allowed, but delivery to the hub failed.
  failed,
}

typedef LocalSend = Future<SendOutcome> Function(String to, String text);

/// Largest accepted request body. A chat message, not a file upload.
const maxSendBodyBytes = 256 * 1024;

/// Starts `POST /send` on 127.0.0.1:[port] so local tools and cron jobs can
/// post into Jay through the bridge.
///
/// WHY fail-closed: anything on the host could reach a loopback port, and the
/// bot speaks with its owner's trust. Without a [key] there is no endpoint at
/// all (returns null), never an open one.
///
/// Answers: 202 sent, 400 bad body, 401 bad key, 403 target not allowed,
/// 404 unknown path, 405 wrong method, 502 hub delivery failed.
Future<HttpServer?> startSendEndpoint({
  required String? key,
  required LocalSend send,
  required void Function(String) log,
  int port = 8650,
}) async {
  if (key == null || key.trim().isEmpty) return null;
  final expected = utf8.encode('Bearer ${key.trim()}');
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  server.listen((request) async {
    try {
      final (status, body) = await _serve(request, expected, send, log);
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(body));
    } catch (e) {
      log('/send: internal error: $e');
      request.response.statusCode = HttpStatus.internalServerError;
    }
    await request.response.close();
  });
  log('Local send endpoint on http://127.0.0.1:${server.port}/send');
  return server;
}

Future<(int, Object)> _serve(
  HttpRequest request,
  List<int> expectedAuth,
  LocalSend send,
  void Function(String) log,
) async {
  if (request.uri.path != '/send') return (404, {'error': 'not_found'});
  if (request.method != 'POST') return (405, {'error': 'method_not_allowed'});
  final auth = request.headers.value(HttpHeaders.authorizationHeader) ?? '';
  if (!_constantTimeEquals(utf8.encode(auth), expectedAuth)) {
    // The key itself is never logged.
    log('/send: rejected a request with a wrong or missing key');
    return (401, {'error': 'unauthorized'});
  }
  final bytes = <int>[];
  await for (final chunk in request) {
    bytes.addAll(chunk);
    if (bytes.length > maxSendBodyBytes) return (400, {'error': 'too_large'});
  }
  final String to;
  final String text;
  try {
    final json = jsonDecode(utf8.decode(bytes));
    if (json is! Map ||
        json['to'] is! String ||
        json['text'] is! String ||
        (json['to'] as String).trim().isEmpty ||
        (json['text'] as String).trim().isEmpty) {
      return (400, {'error': 'expected {"to": string, "text": string}'});
    }
    to = (json['to'] as String).trim();
    text = json['text'] as String;
  } on FormatException {
    return (400, {'error': 'invalid_json'});
  }
  return switch (await send(to, text)) {
    SendOutcome.sent => (202, {'status': 'sent'}),
    SendOutcome.forbidden => (403, {'error': 'target_not_allowed'}),
    SendOutcome.failed => (502, {'error': 'delivery_failed'}),
  };
}

/// WHY constant time: a byte-by-byte early exit leaks how much of the key a
/// guess got right through response timing.
bool _constantTimeEquals(List<int> a, List<int> b) {
  var diff = a.length ^ b.length;
  for (var i = 0; i < a.length && i < b.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
