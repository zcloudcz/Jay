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
  final reacts = <(String, String?, String)>[];
  final logs = <String>[];
  var outcome = SendOutcome.sent;

  setUp(() async {
    sends.clear();
    reacts.clear();
    logs.clear();
    outcome = SendOutcome.sent;
    server = (await startSendEndpoint(
      key: 'secret-key',
      port: 0,
      send: (to, text) async {
        sends.add((to, text));
        return outcome;
      },
      react: (to, messageId, emoji) async {
        reacts.add((to, messageId, emoji));
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

  Future<(int, String)> callFull({
    String method = 'POST',
    String path = '/send',
    String? auth = 'Bearer secret-key',
    Object? body = const {'to': 'CT-AAAA-0001', 'text': 'hi'},
  }) async {
    final request = await client.open(method, '127.0.0.1', server.port, path);
    if (auth != null) request.headers.set('authorization', auth);
    // UTF-8: HttpClientRequest.write defaults to Latin-1, emojis need more.
    if (body != null) {
      request.add(utf8.encode(body is String ? body : jsonEncode(body)));
    }
    final response = await request.close();
    return (response.statusCode, await utf8.decodeStream(response));
  }

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
    'channel outcomes: suspended 403, bot limit 429, bad target 400',
    () async {
      for (final (o, status) in [
        (SendOutcome.channelSuspended, 403),
        (SendOutcome.rateLimited, 429),
        (SendOutcome.badTarget, 400),
        (SendOutcome.textTooLong, 400),
      ]) {
        outcome = o;
        expect(
          await call(body: {'to': 'channel:CH-NEWS-0001', 'text': 'x'}),
          status,
          reason: '$o',
        );
      }
      // The prefix is passed through untouched: routing is the bridge's job.
      expect(sends.last.$1, 'channel:CH-NEWS-0001');
    },
  );

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

  group('/react', () {
    Future<(int, String)> react(
      Object? body, {
      String? auth = 'Bearer secret-key',
      String method = 'POST',
    }) => callFull(path: '/react', body: body, auth: auth, method: method);

    test('202 reacted: the callback gets (to, messageId, emoji)', () async {
      expect(
        await react({
          'to': ' CT-AAAA-0001 ',
          'messageId': 'm1',
          'emoji': '👍🏽',
        }),
        (202, '{"status":"reacted"}'),
      );
      expect(reacts.single, ('CT-AAAA-0001', 'm1', '👍🏽'));
      expect(sends, isEmpty);
    });

    test('messageId is optional (null = the bridge picks the last one), '
        'emoji "" removes', () async {
      expect((await react({'to': 'CT-AAAA-0001', 'emoji': ''})).$1, 202);
      expect(reacts.single, ('CT-AAAA-0001', null, ''));
    });

    test('auth: missing or wrong key -> 401, nothing called', () async {
      final body = {'to': 'CT-AAAA-0001', 'emoji': '👍'};
      expect((await react(body, auth: null)).$1, 401);
      expect((await react(body, auth: 'Bearer nope')).$1, 401);
      expect(reacts, isEmpty);
      expect(logs.join('\n'), isNot(contains('secret-key')));
    });

    final badBodies = <String, Object>{
      'not JSON': 'nope{',
      'array': [1],
      'missing emoji': {'to': 'CT-AAAA-0001'},
      'blank to': {'to': ' ', 'emoji': '👍'},
      'emoji not a string': {'to': 'g', 'emoji': 1},
      'messageId not a string': {'to': 'g', 'messageId': 5, 'emoji': '👍'},
      'blank messageId': {'to': 'g', 'messageId': ' ', 'emoji': '👍'},
      'long messageId': {'to': 'g', 'messageId': 'x' * 65, 'emoji': '👍'},
    };
    badBodies.forEach((name, body) {
      test('$name -> 400', () async {
        expect((await react(body)).$1, 400);
        expect(reacts, isEmpty);
      });
    });

    test('invalid emoji -> 400 invalid_emoji', () async {
      for (final emoji in ['ok', '👍👍', ' ']) {
        expect(await react({'to': 'CT-AAAA-0001', 'emoji': emoji}), (
          400,
          '{"error":"invalid_emoji"}',
        ), reason: emoji);
      }
      expect(reacts, isEmpty);
    });

    test('outcomes: 403, 404 no_message, 400 bad_target, 502', () async {
      final body = {'to': 'CT-AAAA-0001', 'emoji': '👍'};
      for (final (o, expected) in [
        (SendOutcome.forbidden, (403, '{"error":"target_not_allowed"}')),
        (SendOutcome.noMessage, (404, '{"error":"no_message"}')),
        (SendOutcome.badTarget, (400, '{"error":"bad_target"}')),
        (SendOutcome.failed, (502, '{"error":"delivery_failed"}')),
      ]) {
        outcome = o;
        expect(await react(body), expected, reason: '$o');
      }
    });

    test('GET /react -> 405; without a react callback /react is 404', () async {
      expect((await react(null, method: 'GET')).$1, 405);
      final plain = (await startSendEndpoint(
        key: 'k',
        port: 0,
        send: (_, _) async => SendOutcome.sent,
        log: (_) {},
      ))!;
      addTearDown(() => plain.close(force: true));
      final request = await client.post('127.0.0.1', plain.port, '/react');
      request.headers.set('authorization', 'Bearer k');
      request.add(
        utf8.encode(jsonEncode({'to': 'CT-AAAA-0001', 'emoji': '👍'})),
      );
      final response = await request.close();
      await response.drain<void>();
      expect(response.statusCode, 404);
    });

    test('/send is unchanged next to it', () async {
      expect(await callFull(), (202, '{"status":"sent"}'));
      expect(sends.single, ('CT-AAAA-0001', 'hi'));
      expect(reacts, isEmpty);
    });
  });
}
