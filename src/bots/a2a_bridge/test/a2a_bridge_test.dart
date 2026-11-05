import 'dart:async';
import 'dart:io';

import 'package:a2a_bridge/a2a_bridge.dart';
import 'package:test/test.dart';

import 'support/fake_a2a_server.dart';

void main() {
  late FakeA2aServer server;
  late Directory dir;
  late A2aClient client;

  setUp(() async {
    server = await FakeA2aServer.start();
    dir = await Directory.systemTemp.createTemp('a2a_bridge_test');
    client = A2aClient(agentUrl: server.url, token: 'secret-token');
  });

  tearDown(() async {
    client.close();
    await server.close();
    await dir.delete(recursive: true);
  });

  String statePath() => '${dir.path}/bot.store.a2a.json';

  Future<A2aBridge> bridge({
    Duration timeout = const Duration(seconds: 5),
    Duration poll = const Duration(milliseconds: 20),
    int maxEdits = 30,
  }) async {
    final card = await client.discover();
    return A2aBridge(
      client: client,
      state: await StateStore.open(statePath()),
      card: card,
      timeout: timeout,
      pollInterval: poll,
      maxProgressEdits: maxEdits,
    );
  }

  group('agent card', () {
    test('agent-card.json: endpoint, version, skills', () async {
      server.cards['/.well-known/agent-card.json'] = v1Card(
        '${server.url}/rpc',
        skills: [
          {'id': 'toolset.web', 'name': 'web', 'description': 'Web search'},
        ],
      );
      final card = await client.discover();
      expect(card.name, 'Test Agent');
      expect(card.skills.single.id, 'toolset.web');
      expect(client.endpoint.toString(), '${server.url}/rpc');
      expect(client.version, A2aVersion.v1);
      expect(server.cardRequests.map((r) => r.path), [
        '/.well-known/agent-card.json',
      ]);
    });

    test(
      'falls back to the legacy agent.json and the v0.3 url field',
      () async {
        server.cards['/.well-known/agent.json'] = v03Card(
          '${server.url}/legacy',
        );
        final card = await client.discover();
        expect(card.name, 'Old Agent');
        expect(server.cardRequests.map((r) => r.path), [
          '/.well-known/agent-card.json',
          '/.well-known/agent.json',
        ]);
        expect(client.endpoint.toString(), '${server.url}/legacy');
        // A v0.3 card makes v0.3 the first guess.
        expect(client.version, A2aVersion.v03);
      },
    );

    test('no card at all is an error naming both paths', () async {
      await expectLater(
        client.discover(),
        throwsA(
          isA<A2aException>().having(
            (e) => e.message,
            'message',
            allOf(contains('agent-card.json'), contains('agent.json')),
          ),
        ),
      );
    });

    test('refuses a card endpoint on another origin (token leak)', () async {
      server.cards['/.well-known/agent-card.json'] = v1Card(
        'https://evil.example/rpc',
      );
      await expectLater(client.discover(), throwsA(isA<A2aConfigException>()));
    });

    test('A2A_ENDPOINT_URL overrides the card endpoint', () async {
      server.cards['/.well-known/agent-card.json'] = v1Card(
        'https://public.example/rpc',
      );
      final c = A2aClient(
        agentUrl: server.url,
        endpointOverride: '${server.url}/internal',
      );
      await c.discover();
      expect(c.endpoint.toString(), '${server.url}/internal');
      c.close();
    });

    test('a card without any JSON-RPC interface is refused', () async {
      server.cards['/.well-known/agent-card.json'] = {
        'name': 'gRPC only',
        'supportedInterfaces': [
          {'url': '${server.url}/grpc', 'protocolBinding': 'GRPC'},
        ],
      };
      await expectLater(client.discover(), throwsA(isA<A2aConfigException>()));
    });
  });

  group('messages', () {
    setUp(() {
      server.cards['/.well-known/agent-card.json'] = v1Card('${server.url}/');
    });

    test('v1.0 SendMessage shape, bearer header and a Message reply', () async {
      server.onRpc = (call) => ok({
        'message': {
          'role': 'ROLE_AGENT',
          'messageId': 'r1',
          'contextId': 'ctx-9',
          'parts': [
            {'text': 'Hello from the agent'},
          ],
        },
      });
      final b = await bridge();
      final sink = FakeSink();
      await b.handle(conversationId: 'conv-1', text: 'Hi', sink: sink);

      expect(sink.events, ['reply:Hello from the agent']);
      final call = server.calls.single;
      expect(call.method, 'SendMessage');
      expect(call.headers.value('authorization'), 'Bearer secret-token');
      expect(call.headers.value('a2a-version'), '1.0');
      expect(call.message['role'], 'ROLE_USER');
      expect(call.message['parts'], [
        {'text': 'Hi'},
      ]);
      expect(call.message['messageId'], isNotEmpty);
      expect(call.message.containsKey('contextId'), isFalse);
      // The card fetch carried the token too (same origin).
      expect(
        server.cardRequests.first.headers.value('authorization'),
        'Bearer secret-token',
      );
      expect(b.state.get('conv-1').contextId, 'ctx-9');
    });

    test(
      'completed task: artifact text, duplicate status text not repeated',
      () async {
        server.onRpc = (call) => ok({
          'task': v1Task('t1', 'TASK_STATE_COMPLETED', text: 'The answer'),
        });
        final sink = FakeSink();
        await (await bridge()).handle(
          conversationId: 'c',
          text: 'Q',
          sink: sink,
        );
        expect(sink.events, ['reply:The answer']);
      },
    );

    test(
      'completed task: status note and several artifacts are combined',
      () async {
        server.onRpc = (call) => ok({
          'task': {
            'id': 't2',
            'contextId': 'ctx-2',
            'status': {
              'state': 'TASK_STATE_COMPLETED',
              'message': {
                'role': 'ROLE_AGENT',
                'parts': [
                  {'text': 'Done, two files.'},
                ],
              },
            },
            'artifacts': [
              {
                'parts': [
                  {'text': 'first'},
                ],
              },
              {
                'parts': [
                  {'url': 'https://x.example/r.pdf', 'filename': 'r.pdf'},
                  {
                    'data': {'n': 1},
                  },
                ],
              },
            ],
          },
        });
        final sink = FakeSink();
        await (await bridge()).handle(
          conversationId: 'c',
          text: 'Q',
          sink: sink,
        );
        expect(sink.events, [
          'reply:Done, two files.\n\nfirst\n\n'
              '[file: r.pdf] https://x.example/r.pdf\n{"n":1}',
        ]);
      },
    );

    test(
      'input-required: question shown, follow-up carries taskId + contextId',
      () async {
        var n = 0;
        server.onRpc = (call) {
          n++;
          return n == 1
              ? ok({
                  'task': v1Task(
                    'task-a',
                    'TASK_STATE_INPUT_REQUIRED',
                    text: 'Which city?',
                    contextId: 'ctx-a',
                  ),
                })
              : ok({
                  'task': v1Task(
                    'task-a',
                    'TASK_STATE_COMPLETED',
                    text: 'Sunny in Prague',
                    contextId: 'ctx-a',
                  ),
                });
        };
        final b = await bridge();
        final sink = FakeSink();
        await b.handle(conversationId: 'c', text: 'Weather?', sink: sink);
        expect(b.state.get('c').taskId, 'task-a');
        await b.handle(conversationId: 'c', text: 'Prague', sink: sink);

        expect(sink.events, ['reply:Which city?', 'reply:Sunny in Prague']);
        final follow = server.calls[1].message;
        expect(follow['taskId'], 'task-a');
        expect(follow['contextId'], 'ctx-a');
        // Completed: the task is closed, the context stays.
        expect(b.state.get('c').taskId, isNull);
        expect(b.state.get('c').contextId, 'ctx-a');
      },
    );

    test('a refused remembered task is retried once as a new task', () async {
      var n = 0;
      server.onRpc = (call) {
        n++;
        if (n == 1) {
          return ok({
            'task': v1Task('old', 'TASK_STATE_INPUT_REQUIRED', text: 'More?'),
          });
        }
        if (call.message.containsKey('taskId')) {
          return rpcError(-32001, 'task not found');
        }
        return ok({'task': v1Task('new', 'TASK_STATE_COMPLETED', text: 'OK')});
      };
      final b = await bridge();
      final sink = FakeSink();
      await b.handle(conversationId: 'c', text: 'a', sink: sink);
      await b.handle(conversationId: 'c', text: 'b', sink: sink);
      expect(sink.events.last, 'reply:OK');
      expect(server.calls.last.message.containsKey('taskId'), isFalse);
      expect(server.calls.last.message['contextId'], 'ctx-1');
    });

    test(
      'working -> poll GetTask -> completed, progress posted and edited',
      () async {
        var polls = 0;
        server.onRpc = (call) {
          if (call.method == 'SendMessage') {
            return ok({'task': v1Task('t-w', 'TASK_STATE_SUBMITTED')});
          }
          expect(call.method, 'GetTask');
          expect(call.params['id'], 't-w');
          polls++;
          if (polls == 1) return ok(v1Task('t-w', 'TASK_STATE_WORKING'));
          if (polls == 2) {
            return ok(v1Task('t-w', 'TASK_STATE_WORKING', text: 'Searching'));
          }
          if (polls == 3) {
            // Same status again: must NOT cause another edit.
            return ok(v1Task('t-w', 'TASK_STATE_WORKING', text: 'Searching'));
          }
          return ok(v1Task('t-w', 'TASK_STATE_COMPLETED', text: 'Found it'));
        };
        final sink = FakeSink();
        await (await bridge()).handle(
          conversationId: 'c',
          text: 'go',
          sink: sink,
        );
        expect(sink.events, [
          'progress:${BridgeTexts.working}',
          'edit:${BridgeTexts.working}\nSearching',
          'edit:Found it',
        ]);
        expect(polls, 4);
      },
    );

    test('progress edits are capped', () async {
      var polls = 0;
      server.onRpc = (call) {
        if (call.method == 'SendMessage') {
          return ok({'task': v1Task('t', 'TASK_STATE_WORKING')});
        }
        polls++;
        return polls < 6
            ? ok(v1Task('t', 'TASK_STATE_WORKING', text: 'step $polls'))
            : ok(v1Task('t', 'TASK_STATE_COMPLETED', text: 'end'));
      };
      final sink = FakeSink();
      await (await bridge(
        maxEdits: 2,
      )).handle(conversationId: 'c', text: 'go', sink: sink);
      expect(sink.events.where((e) => e.contains('\nstep ')), hasLength(2));
      expect(sink.events.last, 'edit:end');
    });

    test('a task that never finishes times out with a clear message', () async {
      server.onRpc = (call) => call.method == 'SendMessage'
          ? ok({'task': v1Task('t', 'TASK_STATE_WORKING')})
          : ok(v1Task('t', 'TASK_STATE_WORKING'));
      final sink = FakeSink();
      final b = await bridge(timeout: const Duration(milliseconds: 300));
      await b.handle(conversationId: 'c', text: 'go', sink: sink);
      expect(sink.events.first, 'progress:${BridgeTexts.working}');
      expect(
        sink.events.last,
        'edit:${BridgeTexts.timeout(const Duration(milliseconds: 300))}',
      );
    });

    test('a blocking send that exceeds the timeout is aborted', () async {
      server.onRpc = (call) async {
        await Future<void>.delayed(const Duration(seconds: 2));
        return ok({'task': v1Task('t', 'TASK_STATE_COMPLETED', text: 'late')});
      };
      final sink = FakeSink();
      final watch = Stopwatch()..start();
      await (await bridge(
        timeout: const Duration(milliseconds: 300),
      )).handle(conversationId: 'c', text: 'go', sink: sink);
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 1500)));
      expect(sink.events, [
        'reply:${BridgeTexts.timeout(const Duration(milliseconds: 300))}',
      ]);
    });

    test(
      'failed and rejected tasks give a short error with the reason',
      () async {
        var state = 'TASK_STATE_FAILED';
        server.onRpc = (call) =>
            ok({'task': v1Task('t', state, text: 'disk full')});
        final b = await bridge();
        final sink = FakeSink();
        await b.handle(conversationId: 'c', text: 'x', sink: sink);
        state = 'TASK_STATE_REJECTED';
        await b.handle(conversationId: 'c', text: 'y', sink: sink);
        state = 'TASK_STATE_CANCELED';
        await b.handle(conversationId: 'c', text: 'z', sink: sink);
        expect(sink.events, [
          'reply:The agent failed: disk full',
          'reply:The agent rejected the request: disk full\n'
              '(Send /reset to start a new conversation.)',
          'reply:${BridgeTexts.canceled}',
        ]);
      },
    );

    test(
      '-32601 on SendMessage falls back to v0.3 message/send and sticks',
      () async {
        var polls = 0;
        server.onRpc = (call) {
          switch (call.method) {
            case 'message/send':
              return ok({
                'kind': 'task',
                'id': 't3',
                'contextId': 'ctx-03',
                'status': {'state': 'working'},
              });
            case 'tasks/get':
              polls++;
              return ok({
                'kind': 'task',
                'id': 't3',
                'contextId': 'ctx-03',
                'status': {
                  'state': 'completed',
                  'message': {
                    'kind': 'message',
                    'role': 'agent',
                    'parts': [
                      {'kind': 'text', 'text': 'old school'},
                    ],
                  },
                },
              });
            default:
              return rpcError(-32601, 'method not found');
          }
        };
        final b = await bridge();
        final sink = FakeSink();
        await b.handle(conversationId: 'c', text: 'hi', sink: sink);
        await b.handle(conversationId: 'c', text: 'again', sink: sink);

        expect(server.calls.map((c) => c.method), [
          'SendMessage',
          'message/send',
          'tasks/get',
          'message/send', // remembered: no second SendMessage attempt
          'tasks/get',
        ]);
        final v03 = server.calls[1];
        expect(v03.message['role'], 'user');
        expect(v03.message['kind'], 'message');
        expect(v03.message['parts'], [
          {'kind': 'text', 'text': 'hi'},
        ]);
        // v0.3 requests go without the A2A-Version header (empty = 0.3).
        expect(v03.headers.value('a2a-version'), isNull);
        expect(server.calls[3].message['contextId'], 'ctx-03');
        expect(sink.events.last, 'edit:old school');
        expect(polls, 2);
      },
    );

    test('HTTP 401 tells the user to check A2A_TOKEN', () async {
      server.onRpc = (call) => const FakeReply(401, {
        'jsonrpc': '2.0',
        'id': null,
        'error': {'code': -32050, 'message': 'unauthorized'},
      });
      final sink = FakeSink();
      await (await bridge()).handle(conversationId: 'c', text: 'x', sink: sink);
      expect(sink.events, ['reply:${BridgeTexts.auth(401)}']);
      expect(sink.events.single, contains('A2A_TOKEN'));
    });

    test('long answers are chunked', () async {
      final long = List.filled(1000, 'word').join(' '); // 4999 chars
      server.onRpc = (call) =>
          ok({'task': v1Task('t', 'TASK_STATE_COMPLETED', text: long)});
      final sink = FakeSink();
      await (await bridge()).handle(conversationId: 'c', text: 'x', sink: sink);
      expect(sink.events, hasLength(2));
      expect(
        sink.events.every((e) => e.length <= 'reply:'.length + 4000),
        isTrue,
      );
    });

    test('group sender label is prefixed', () async {
      server.onRpc = (call) => ok({
        'message': {
          'parts': [
            {'text': 'ok'},
          ],
        },
      });
      await (await bridge()).handle(
        conversationId: 'g',
        text: 'hello',
        sink: FakeSink(),
        senderLabel: 'CT-AAAA-BBBB',
      );
      expect(server.calls.single.message['parts'], [
        {'text': '[from CT-AAAA-BBBB] hello'},
      ]);
    });
  });

  group('state persistence', () {
    setUp(() {
      server.cards['/.well-known/agent-card.json'] = v1Card('${server.url}/');
    });

    test('contextId and open taskId survive a restart', () async {
      server.onRpc = (call) => ok({
        'task': v1Task(
          'task-p',
          'TASK_STATE_INPUT_REQUIRED',
          text: 'Need more',
          contextId: 'ctx-p',
        ),
      });
      await (await bridge()).handle(
        conversationId: 'Conv-X',
        text: 'start',
        sink: FakeSink(),
      );
      expect(File('${statePath()}.tmp').existsSync(), isFalse);

      // "Restart": a fresh client, store and bridge from the same file.
      client.close();
      client = A2aClient(agentUrl: server.url, token: 'secret-token');
      final restarted = await bridge();
      expect(restarted.state.get('conv-x').contextId, 'ctx-p');
      await restarted.handle(
        conversationId: 'conv-x',
        text: 'more',
        sink: FakeSink(),
      );
      expect(server.calls.last.message['contextId'], 'ctx-p');
      expect(server.calls.last.message['taskId'], 'task-p');
    });

    test('/reset forgets the conversation without calling the agent', () async {
      final store = await StateStore.open(statePath());
      await store.set(
        'c',
        const ConversationState(contextId: 'ctx', taskId: 't'),
      );
      final card = await client.discover();
      final b = A2aBridge(client: client, state: store, card: card);
      final sink = FakeSink();
      await b.handle(conversationId: 'c', text: '/reset', sink: sink);
      expect(sink.events, ['reply:${BridgeTexts.reset}']);
      expect(server.calls, isEmpty);
      expect((await StateStore.open(statePath())).get('c').isEmpty, isTrue);
    });

    test('a corrupt state file is moved aside, not fatal', () async {
      await File(statePath()).writeAsString('{not json');
      final store = await StateStore.open(statePath());
      expect(store.get('c').isEmpty, isTrue);
      expect(File('${statePath()}.corrupt').existsSync(), isTrue);
    });

    test('concurrent writes of two conversations both persist', () async {
      final store = await StateStore.open(statePath());
      await Future.wait([
        store.set('a', const ConversationState(contextId: '1')),
        store.set('b', const ConversationState(contextId: '2')),
      ]);
      final reread = await StateStore.open(statePath());
      expect(reread.get('a').contextId, '1');
      expect(reread.get('b').contextId, '2');
    });
  });

  test('skill command is sent as a readable skill prefix', () async {
    server.cards['/.well-known/agent-card.json'] = v1Card(
      '${server.url}/',
      skills: [
        {'id': 'toolset.web', 'name': 'web', 'description': 'Web'},
      ],
    );
    server.onRpc = (call) => ok({
      'message': {
        'parts': [
          {'text': 'ok'},
        ],
      },
    });
    final b = await bridge();
    expect(b.commands.map((c) => c.command), ['reset', 'toolset_web']);
    await b.handle(
      conversationId: 'c',
      text: '/toolset_web@CT-ABCD-EFGH latest news',
      sink: FakeSink(),
    );
    expect(server.calls.single.message['parts'], [
      {'text': '[Skill: toolset.web] latest news'},
    ]);
  });
}
