import 'package:llm_bridge/llm_bridge.dart';
import 'package:test/test.dart';

import 'support/fake_llm_server.dart';

void main() {
  late FakeLlmServer server;
  setUp(() async => server = await FakeLlmServer.start());
  tearDown(() => server.close());

  const history = [
    ChatTurn.user('Ahoj'),
    ChatTurn.assistant('Ahoj, jak se máš?'),
    ChatTurn.user('Dobře. Kolik je 2+2?'),
  ];

  group('anthropic', () {
    AnthropicProvider provider({String? effort = 'low'}) => AnthropicProvider(
      apiKey: 'test-key-not-real',
      model: 'claude-sonnet-5-5',
      baseUrl: server.url,
      maxTokens: 1000,
      effort: effort,
    );

    test('request shape: headers, system, history, stream, effort', () async {
      server.answers.add(FakeAnswer.sse(anthropicStream(['4'])));
      final p = provider();
      expect(await p.reply(history, system: 'Be nice.').join(), '4');
      await p.close();

      final r = server.requests.single;
      expect(r.method, 'POST');
      expect(r.path, '/v1/messages');
      expect(r.headers['x-api-key'], 'test-key-not-real');
      expect(r.headers['anthropic-version'], '2023-06-01');
      expect(r.headers.containsKey('authorization'), isFalse);
      expect(r.body, {
        'model': 'claude-sonnet-5-5',
        'max_tokens': 1000,
        'system': 'Be nice.',
        'messages': [
          {'role': 'user', 'content': 'Ahoj'},
          {'role': 'assistant', 'content': 'Ahoj, jak se máš?'},
          {'role': 'user', 'content': 'Dobře. Kolik je 2+2?'},
        ],
        'stream': true,
        'output_config': {'effort': 'low'},
      });
    });

    test('no effort configured: output_config is omitted', () async {
      server.answers.add(FakeAnswer.sse(anthropicStream(['ok'])));
      final p = provider(effort: null);
      await p.reply(history, system: 's').join();
      await p.close();
      expect(server.requests.single.body.containsKey('output_config'), isFalse);
    });

    test('streams text deltas in order and skips thinking', () async {
      server.answers.add(
        FakeAnswer.sse(
          anthropicStream(['Dva ', 'plus ', 'dva ', 'jsou ', 'čtyři.']),
          pause: const Duration(milliseconds: 5),
        ),
      );
      final p = provider();
      final pieces = await p.reply(history, system: 's').toList();
      await p.close();
      expect(pieces, ['Dva ', 'plus ', 'dva ', 'jsou ', 'čtyři.']);
    });

    test('mid-stream error event becomes an LlmException', () async {
      server.answers.add(
        FakeAnswer.sse([
          anthropicStream(['par']).first,
          'event: error\ndata: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}\n\n',
        ]),
      );
      final p = provider();
      await expectLater(
        p.reply(history, system: 's').join(),
        throwsA(
          isA<LlmException>()
              .having((e) => e.message, 'message', 'Overloaded')
              .having((e) => e.status, 'status', 529),
        ),
      );
      await p.close();
    });

    test('HTTP 401 carries the vendor message and status', () async {
      server.answers.add(
        FakeAnswer.json({
          'type': 'error',
          'error': {
            'type': 'authentication_error',
            'message': 'invalid x-api-key',
          },
        }, status: 401),
      );
      final p = provider();
      await expectLater(
        p.reply(history, system: 's').join(),
        throwsA(
          isA<LlmException>()
              .having((e) => e.isAuth, 'isAuth', isTrue)
              .having((e) => e.message, 'message', 'invalid x-api-key'),
        ),
      );
      await p.close();
    });

    test('HTTP 429 exposes retry-after', () async {
      server.answers.add(
        FakeAnswer.json(
          {
            'error': {'type': 'rate_limit_error', 'message': 'slow down'},
          },
          status: 429,
          headers: {'retry-after': '7'},
        ),
      );
      final p = provider();
      await expectLater(
        p.reply(history, system: 's').join(),
        throwsA(
          isA<LlmException>()
              .having((e) => e.isRateLimit, 'isRateLimit', isTrue)
              .having(
                (e) => e.retryAfter,
                'retryAfter',
                const Duration(seconds: 7),
              ),
        ),
      );
      await p.close();
    });

    test('history is normalised: starts with user, roles alternate', () {
      final body = provider().requestBody(const [
        ChatTurn.assistant('Ahoj, jsem bot.'),
        ChatTurn.user('a'),
        ChatTurn.user('b'),
        ChatTurn.assistant('c'),
      ], 's');
      expect(body['messages'], [
        {'role': 'user', 'content': 'a\n\nb'},
        {'role': 'assistant', 'content': 'c'},
      ]);
    });

    test('unreachable host is an LlmException, not a crash', () async {
      final p = AnthropicProvider(
        apiKey: 'k',
        model: 'm',
        baseUrl: 'http://127.0.0.1:1',
      );
      await expectLater(
        p.reply(history, system: 's').join(),
        throwsA(isA<LlmException>()),
      );
      await p.close();
    });
  });

  group('openai', () {
    test('official host: bearer, system first, max_completion_tokens, '
        'reasoning_effort', () {
      final p = OpenAiProvider(
        apiKey: 'k',
        model: 'gpt-6.1-sol',
        maxTokens: 900,
        effort: 'low',
      );
      expect(p.requestBody(history, 'Be nice.'), {
        'model': 'gpt-6.1-sol',
        'messages': [
          {'role': 'system', 'content': 'Be nice.'},
          {'role': 'user', 'content': 'Ahoj'},
          {'role': 'assistant', 'content': 'Ahoj, jak se máš?'},
          {'role': 'user', 'content': 'Dobře. Kolik je 2+2?'},
        ],
        'stream': true,
        'max_completion_tokens': 900,
        'reasoning_effort': 'low',
      });
    });

    test(
      'compatible server: max_tokens, no key header, streams until [DONE]',
      () async {
        server.answers.add(
          FakeAnswer.sse(
            openAiStream(['Čty', 'ři.']),
            pause: const Duration(milliseconds: 5),
          ),
        );
        final p = OpenAiProvider(
          model: 'llama3.3',
          baseUrl: '${server.url}/v1',
        );
        final pieces = await p.reply(history, system: 's').toList();
        await p.close();
        expect(pieces, ['Čty', 'ři.']);
        final r = server.requests.single;
        expect(r.path, '/v1/chat/completions');
        expect(r.headers.containsKey('authorization'), isFalse);
        expect(r.body['max_tokens'], 8192);
        expect(r.body.containsKey('max_completion_tokens'), isFalse);
        expect(r.body.containsKey('reasoning_effort'), isFalse);
      },
    );

    test('a key is sent as bearer to a compatible server', () async {
      server.answers.add(FakeAnswer.sse(openAiStream(['x'])));
      final p = OpenAiProvider(
        apiKey: 'or-test-key',
        model: 'some/model',
        baseUrl: server.url,
      );
      await p.reply(history, system: 's').join();
      await p.close();
      expect(
        server.requests.single.headers['authorization'],
        'Bearer or-test-key',
      );
      expect(server.requests.single.headers.containsKey('api-key'), isFalse);
    });

    test('error object inside the stream becomes an LlmException', () async {
      server.answers.add(
        FakeAnswer.sse(['data: {"error":{"message":"model not loaded"}}\n\n']),
      );
      final p = OpenAiProvider(model: 'm', baseUrl: server.url);
      await expectLater(
        p.reply(history, system: 's').join(),
        throwsA(
          isA<LlmException>().having((e) => e.message, 'm', 'model not loaded'),
        ),
      );
      await p.close();
    });

    test('HTTP 500 with a plain string error', () async {
      server.answers.add(FakeAnswer.json({'error': 'boom'}, status: 500));
      final p = OpenAiProvider(model: 'm', baseUrl: server.url);
      await expectLater(
        p.reply(history, system: 's').join(),
        throwsA(
          isA<LlmException>()
              .having((e) => e.message, 'm', 'boom')
              .having((e) => e.status, 's', 500),
        ),
      );
      await p.close();
    });
  });

  group('sse parser', () {
    test(
      'multi-line data, comments and a final event without blank line',
      () async {
        final events = await parseSse(
          Stream.fromIterable([
            ': comment\n'.codeUnits,
            'event: a\ndata: one\ndata: two\n\n'.codeUnits,
            'data:three'.codeUnits,
          ]),
        ).toList();
        expect(events.map((e) => (e.event, e.data)), [
          ('a', 'one\ntwo'),
          (null, 'three'),
        ]);
      },
    );
  });
}
