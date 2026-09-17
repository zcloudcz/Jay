import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:calltype_bot/calltype_bot.dart';
import 'package:hermes_bridge/hermes_bridge.dart';
import 'package:test/test.dart';

// The runtime's fakes (real-crypto user, fake hub, loopback API) are reused
// rather than duplicated; they live in the sibling package's test folder.
import '../../calltype_bot/test/helpers.dart';

/// Loopback stand-in for the Hermes API server. [respond] decides per request.
class FakeHermes {
  FakeHermes._(this._server);
  final HttpServer _server;
  final requests = <({String path, String? auth, Map<String, dynamic> body})>[];
  late FutureOr<(int, Object?)> Function(String path, int nth) respond;

  String get url => 'http://127.0.0.1:${_server.port}';

  static Future<FakeHermes> start() async {
    final fake = FakeHermes._(await HttpServer.bind('127.0.0.1', 0));
    fake._server.listen((request) async {
      final body = jsonDecode(await utf8.decodeStream(request));
      fake.requests.add((
        path: request.uri.path,
        auth: request.headers.value('authorization'),
        body: body as Map<String, dynamic>,
      ));
      final (status, json) = await fake.respond(
        request.uri.path,
        fake.requests.length,
      );
      request.response.statusCode = status;
      request.response.write(jsonEncode(json));
      await request.response.close();
    });
    return fake;
  }

  Future<void> close() => _server.close(force: true);
}

Object _reply(String text) => {
  'object': 'hermes.session.chat.completion',
  'message': {'role': 'assistant', 'content': text},
};

void main() {
  group('HermesClient', () {
    late FakeHermes hermes;
    late HermesClient client;

    setUp(() async {
      hermes = await FakeHermes.start();
      client = HermesClient(
        baseUrl: hermes.url,
        apiKey: 'key',
        timeout: const Duration(milliseconds: 300),
        retryDelay: Duration.zero,
      );
    });
    tearDown(() async {
      client.close();
      await hermes.close();
    });

    test('happy path: session-scoped chat with bearer auth', () async {
      hermes.respond = (_, _) => (200, _reply('hello'));
      expect(await client.ask('hi', conversationId: 'conv-1'), 'hello');
      final request = hermes.requests.single;
      expect(request.path, '/api/sessions/calltype-conv-1/chat');
      expect(request.auth, 'Bearer key');
      expect(request.body, {'message': 'hi'});
    });

    test('unknown session (404) is created, then the chat is repeated', () async {
      hermes.respond = (path, nth) => switch (nth) {
        1 => (404, {'error': {}}),
        2 => (201, {'object': 'hermes.session'}),
        _ => (200, _reply('first answer')),
      };
      expect(await client.ask('hi', conversationId: 'c'), 'first answer');
      expect(hermes.requests.map((r) => r.path), [
        '/api/sessions/calltype-c/chat',
        '/api/sessions',
        '/api/sessions/calltype-c/chat',
      ]);
      expect(hermes.requests[1].body, {'id': 'calltype-c'});
    });

    test('HTTP 500 is retried exactly once', () async {
      hermes.respond = (_, nth) => nth == 1 ? (500, null) : (200, _reply('ok'));
      expect(await client.ask('hi', conversationId: 'c'), 'ok');
      expect(hermes.requests, hasLength(2));

      hermes.requests.clear();
      hermes.respond = (_, _) => (500, null);
      await expectLater(
        client.ask('hi', conversationId: 'c'),
        throwsA(isA<HttpException>()),
      );
      expect(hermes.requests, hasLength(2));
    });

    test('timeout fails WITHOUT a retry (the turn may still be running)', () async {
      hermes.respond = (_, _) async {
        await Future<void>.delayed(const Duration(seconds: 1));
        return (200, _reply('too late'));
      };
      await expectLater(
        client.ask('hi', conversationId: 'c'),
        throwsA(isA<TimeoutException>()),
      );
      expect(hermes.requests, hasLength(1));
    });
  });

  test('parseAllowedHandles trims, upper-cases and drops blanks', () {
    expect(parseAllowedHandles(null), isEmpty);
    expect(parseAllowedHandles(' , '), isEmpty);
    expect(parseAllowedHandles('ct-aaaa-0001, CT-BBBB-0002,'), {
      'CT-AAAA-0001',
      'CT-BBBB-0002',
    });
  });

  test('splitMessage keeps words whole and respects the limit', () {
    expect(splitMessage('short'), ['short']);
    final chunks = splitMessage('aaa bbb ccc ddd', limit: 8);
    expect(chunks, ['aaa bbb', 'ccc ddd']);
    expect(splitMessage('x' * 25, limit: 10).map((c) => c.length), [10, 10, 5]);
    expect(splitMessage('line one\nline two', limit: 12), ['line one', 'line two']);
  });

  group('runBridge allowlist', () {
    late Directory dir;
    late FakeApi api;
    late FakeHub hub;
    late FakeUser alice;
    late CallTypeBot bot;
    final backendCalls = <String>[];
    final logs = <String>[];

    Future<String> backend(String text, {required String conversationId}) async {
      backendCalls.add('$conversationId: $text');
      return 'answer to $text';
    }

    setUp(() async {
      backendCalls.clear();
      logs.clear();
      dir = await Directory.systemTemp.createTemp('hermes_bridge_test');
      api = await FakeApi.start();
      hub = FakeHub();
      alice = await FakeUser.create('00000000-0000-4000-8000-00000000000a');
      api.handles['CT-AAAA-0001'] = alice.id;
      bot = await CallTypeBot.start(
        apiBaseUrl: api.url,
        storePath: '${dir.path}/bot.store',
        storeKeyBase64: testStoreKey,
        transportFactory: (_, _) => hub,
        log: logs.add,
      );
    });
    tearDown(() async {
      await bot.close();
      await alice.close();
      await api.close();
      await dir.delete(recursive: true);
    });

    test('allowed handle: backend called with the conversation id, reply sent', () async {
      await runBridge(
        bot,
        allowedHandles: {'CT-AAAA-0001'},
        backend: backend,
        log: logs.add,
      );
      hub.deliver(await alice.messageTo(bot.deviceId, api.botBundle, 'hi'));
      await until(() => hub.calls('AcknowledgeMessage').isNotEmpty);

      expect(backendCalls, ['${alice.id}: hi']);
      final sent = hub.calls('SendReliableMessage').single;
      expect(await alice.read(bot.deviceId, sent[2] as String), 'answer to hi');
    });

    test('disallowed handle: backend never called, no reply', () async {
      await runBridge(
        bot,
        allowedHandles: {'CT-SOME-BODY'},
        backend: backend,
        log: logs.add,
      );
      hub.deliver(await alice.messageTo(bot.deviceId, api.botBundle, 'run ls'));
      await until(() => hub.calls('AcknowledgeMessage').isNotEmpty);

      expect(backendCalls, isEmpty);
      expect(hub.calls('SendReliableMessage'), isEmpty);
      expect(hub.calls('TypingIndicator'), isEmpty);
      expect(logs.join('\n'), contains('CT-SOME-BODY is unknown'));
    });

    test('empty allowlist: replies to nobody and logs how to allow', () async {
      await runBridge(bot, allowedHandles: {}, backend: backend, log: logs.add);
      hub.deliver(await alice.messageTo(bot.deviceId, api.botBundle, 'hello?'));
      await until(() => hub.calls('AcknowledgeMessage').isNotEmpty);

      expect(backendCalls, isEmpty);
      expect(hub.calls('SendReliableMessage'), isEmpty);
      expect(logs.join('\n'), contains('Set ALLOWED_HANDLES='));
    });
  });
}
