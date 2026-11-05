import 'dart:convert';
import 'dart:io';

import 'package:hermes_bridge/hermes_bridge.dart';
import 'package:test/test.dart';

/// The local POST /send endpoint in isolation: auth, body validation and
/// status mapping, with a scripted send function instead of a bot.
void main() {
  late HttpServer server;
  late HttpClient client;
  final sends = <(String, String)>[];
  final logs = <String>[];
  var outcome = SendOutcome.sent;

  setUp(() async {
    sends.clear();
    logs.clear();
    outcome = SendOutcome.sent;
    server = (await startSendEndpoint(
      key: 'secret-key',
      port: 0,
      send: (to, text) async {
        sends.add((to, text));
        return outcome;
      },
      log: logs.add,
    ))!;
    client = HttpClient();
  });
  tearDown(() async {
    client.close(force: true);
    await server.close(force: true);
  });

  Future<int> call({
    String method = 'POST',
    String path = '/send',
    String? auth = 'Bearer secret-key',
    Object? body = const {'to': 'CT-AAAA-0001', 'text': 'hi'},
  }) async {
    final request = await client.open(method, '127.0.0.1', server.port, path);
    if (auth != null) request.headers.set('authorization', auth);
    if (body != null) request.write(body is String ? body : jsonEncode(body));
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  }

  test('disabled without a key (fail-closed)', () async {
    for (final key in [null, '', '   ']) {
      expect(
        await startSendEndpoint(
          key: key,
          send: (_, _) async => SendOutcome.sent,
          log: (_) {},
        ),
        isNull,
      );
    }
  });

  test('listens on loopback only', () {
    expect(server.address, InternetAddress.loopbackIPv4);
  });

  final statusCases = <String, (Future<int> Function(), int, int)>{
    // name: (request, expected status, expected number of send calls)
    'valid request -> 202': (() => call(), 202, 1),
    'missing key -> 401': (() => call(auth: null), 401, 0),
    'wrong key -> 401': (() => call(auth: 'Bearer nope'), 401, 0),
    'key without Bearer -> 401': (() => call(auth: 'secret-key'), 401, 0),
    'unknown path -> 404': (() => call(path: '/other'), 404, 0),
    'GET /send -> 405': (() => call(method: 'GET', body: null), 405, 0),
    'not JSON -> 400': (() => call(body: 'nope{'), 400, 0),
    'JSON array -> 400': (() => call(body: [1]), 400, 0),
    'missing text -> 400': (() => call(body: {'to': 'CT-AAAA-0001'}), 400, 0),
    'blank to -> 400': (() => call(body: {'to': ' ', 'text': 'x'}), 400, 0),
    'text not a string -> 400': (
      () => call(body: {'to': 'g', 'text': 5}),
      400,
      0,
    ),
    'too large -> 400': (
      () => call(body: {'to': 'g', 'text': 'x' * (maxSendBodyBytes + 1)}),
      400,
      0,
    ),
  };
  statusCases.forEach((name, c) {
    test(name, () async {
      expect(await c.$1(), c.$2);
      expect(sends, hasLength(c.$3));
    });
  });

  test('forbidden target -> 403, delivery failure -> 502', () async {
    outcome = SendOutcome.forbidden;
    expect(await call(), 403);
    outcome = SendOutcome.failed;
    expect(await call(), 502);
  });

  test(
    'passes the trimmed target and the text unchanged; never logs the key',
    () async {
      await call(body: {'to': '  CT-AAAA-0001 ', 'text': ' two\nlines '});
      expect(sends.single, ('CT-AAAA-0001', ' two\nlines '));
      await call(auth: 'Bearer guess-123');
      expect(logs.join('\n'), isNot(contains('secret-key')));
      expect(logs.join('\n'), isNot(contains('guess-123')));
    },
  );
}
