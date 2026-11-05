import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:calltype_bot/calltype_bot.dart';
import 'package:hermes_bridge/hermes_bridge.dart';
import 'package:test/test.dart';

import '../../calltype_bot/test/helpers.dart';

/// Loopback Hermes for the streaming client: [respond] returns a status and
/// either a JSON value or a raw SSE string ([Sse]).
class _FakeHermes {
  _FakeHermes._(this._server);
  final HttpServer _server;
  final requests = <({String path, Map<String, dynamic> body})>[];
  late FutureOr<(int, Object?)> Function(String path, int nth) respond;

  String get url => 'http://127.0.0.1:${_server.port}';

  static Future<_FakeHermes> start() async {
    final fake = _FakeHermes._(await HttpServer.bind('127.0.0.1', 0));
    fake._server.listen((request) async {
      final body = jsonDecode(await utf8.decodeStream(request));
      fake.requests.add((
        path: request.uri.path,
        body: body as Map<String, dynamic>,
      ));
      final (status, reply) = await fake.respond(
        request.uri.path,
        fake.requests.length,
      );
      request.response.statusCode = status;
      if (reply is Sse) {
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        request.response.write(reply.raw);
      } else {
        request.response.write(jsonEncode(reply));
      }
      await request.response.close();
    });
    return fake;
  }

  Future<void> close() => _server.close(force: true);
}

class Sse {
  const Sse(this.raw);
  final String raw;
}

String _frame(String event, Map<String, dynamic> data) =>
    'event: $event\ndata: ${jsonEncode(data)}\n\n';

Object _reply(String text) => {
  'message': {'role': 'assistant', 'content': text},
};

void main() {
  group('HermesClient streaming', () {
    late _FakeHermes hermes;
    late HermesClient client;
    final logs = <String>[];

    setUp(() async {
      logs.clear();
      hermes = await _FakeHermes.start();
      client = HermesClient(
        baseUrl: hermes.url,
        apiKey: 'k',
        timeout: const Duration(seconds: 2),
        retryDelay: Duration.zero,
        log: logs.add,
      );
    });
    tearDown(() async {
      client.close();
      await hermes.close();
    });

    test('parses the real event names and stops at done', () async {
      hermes.respond = (_, _) => (
        200,
        Sse(
          [
            _frame('run.started', {'run_id': 'run_1'}),
            ': keepalive\n\n',
            _frame('assistant.delta', {'message_id': 'm', 'delta': 'Hel'}),
            _frame('tool.started', {
              'tool_name': 'terminal',
              'preview': 'ls -la',
            }),
            _frame('tool.progress', {'tool_name': '_thinking', 'delta': 'x'}),
            _frame('tool.completed', {'tool_name': 'terminal'}),
            _frame('approval.request', {
              'event': 'approval.request',
              'run_id': 'run_1',
              'request_id': 'req_1',
              'command': 'rm -rf build',
              'description': 'recursive delete',
              'choices': ['once', 'deny'],
            }),
            _frame('assistant.completed', {'content': 'Hello'}),
            _frame('run.completed', {'message_id': 'm'}),
            _frame('done', {}),
            _frame('assistant.completed', {'content': 'after done'}),
          ].join(),
        ),
      );
      final events = await client.chat('hi', conversationId: 'c').toList();
      expect(
        hermes.requests.single.path,
        '/api/sessions/calltype-c/chat/stream',
      );
      expect(hermes.requests.single.body, {'message': 'hi'});
      expect(events, hasLength(5));
      expect((events[0] as HermesDelta).text, 'Hel');
      final tool = events[1] as HermesToolEvent;
      expect(
        (tool.phase, tool.toolName, tool.preview),
        ('started', 'terminal', 'ls -la'),
      );
      expect((events[2] as HermesToolEvent).phase, 'completed');
      final approval = events[3] as HermesApprovalRequest;
      expect(approval.runId, 'run_1');
      expect(approval.requestId, 'req_1');
      expect(approval.command, 'rm -rf build');
      expect(approval.choices, ['once', 'deny']);
      expect((events[4] as HermesCompleted).content, 'Hello');
    });

    test('unknown session: created, then the stream is retried', () async {
      hermes.respond = (path, nth) => switch (nth) {
        1 => (404, {'error': {}}),
        2 => (201, {'id': 'calltype-c'}),
        _ => (200, Sse(_frame('assistant.completed', {'content': 'ok'}))),
      };
      final events = await client.chat('hi', conversationId: 'c').toList();
      expect((events.single as HermesCompleted).content, 'ok');
      expect(hermes.requests.map((r) => r.path), [
        '/api/sessions/calltype-c/chat/stream',
        '/api/sessions',
        '/api/sessions/calltype-c/chat/stream',
      ]);
    });

    test(
      'no stream route (404 after create): falls back to /chat for good',
      () async {
        hermes.respond = (path, _) => switch (path) {
          '/api/sessions' => (409, {'error': {}}),
          '/api/sessions/calltype-c/chat' => (200, _reply('plain')),
          _ => (404, {'error': {}}),
        };
        final first = await client.chat('hi', conversationId: 'c').toList();
        expect((first.single as HermesCompleted).content, 'plain');
        expect(hermes.requests.map((r) => r.path), [
          '/api/sessions/calltype-c/chat/stream',
          '/api/sessions',
          '/api/sessions/calltype-c/chat/stream',
          '/api/sessions/calltype-c/chat',
        ]);
        expect(logs.join(), contains('no streaming chat route'));

        hermes.requests.clear();
        await client.chat('again', conversationId: 'c').toList();
        expect(hermes.requests.map((r) => r.path), [
          '/api/sessions/calltype-c/chat',
        ]);
      },
    );

    test('HERMES_STREAM=false uses /chat only', () async {
      final plain = HermesClient(
        baseUrl: hermes.url,
        apiKey: 'k',
        stream: false,
      );
      addTearDown(plain.close);
      hermes.respond = (_, _) => (200, _reply('plain'));
      final events = await plain.chat('hi', conversationId: 'c').toList();
      expect((events.single as HermesCompleted).content, 'plain');
      expect(hermes.requests.single.path, '/api/sessions/calltype-c/chat');
    });

    test('approve posts choice + request_id; a refusal throws', () async {
      hermes.respond = (_, nth) => nth == 1
          ? (200, {'object': 'hermes.run.approval_response'})
          : (
              409,
              {
                'error': {'code': 'approval_not_pending'},
              },
            );
      await client.approve('run_1', 'req_1', 'session');
      expect(hermes.requests.single.path, '/v1/runs/run_1/approval');
      expect(hermes.requests.single.body, {
        'choice': 'session',
        'request_id': 'req_1',
      });
      await expectLater(
        client.approve('run_1', 'req_1', 'once'),
        throwsA(
          isA<HttpException>().having(
            (e) => e.message,
            'message',
            contains('approval_not_pending'),
          ),
        ),
      );
    });
  });

  group('parseBotCommands', () {
    test('cmd:description pairs, optional slash, blanks skipped', () {
      expect(parseBotCommands(null), isEmpty);
      expect(parseBotCommands(' ; '), isEmpty);
      expect(
        parseBotCommands('help:Show help; /status : Bot status: short;'),
        const [
          BotCommand(command: 'help', description: 'Show help'),
          BotCommand(command: 'status', description: 'Bot status: short'),
        ],
      );
    });

    test('bad entries stop the start', () {
      expect(() => parseBotCommands('help'), throwsFormatException);
      expect(() => parseBotCommands('Help:x'), throwsFormatException);
      expect(() => parseBotCommands('help:'), throwsFormatException);
      expect(() => parseBotCommands('a:x;a:y'), throwsFormatException);
    });
  });

  group('bridge turns', () {
    const groupId = '00000000-0000-4000-8000-0000000000c0';
    late Directory dir;
    late FakeApi api;
    late FakeHub hub;
    late FakeUser alice;
    late FakeUser peer;
    late CallTypeBot bot;
    late StreamController<HermesEvent> turn;
    final prompts = <String>[];
    final approvals = <(String, String, String)>[];
    final logs = <String>[];
    var readSoFar = 0;

    Stream<HermesEvent> stream(String text, {required String conversationId}) {
      prompts.add(text);
      turn = StreamController<HermesEvent>();
      return turn.stream;
    }

    Future<void> approve(String run, String request, String choice) async =>
        approvals.add((run, request, choice));

    setUp(() async {
      prompts.clear();
      approvals.clear();
      logs.clear();
      readSoFar = 0;
      dir = await Directory.systemTemp.createTemp('hermes_bridge_agent');
      api = await FakeApi.start();
      hub = FakeHub();
      alice = await FakeUser.create('00000000-0000-4000-8000-00000000000a');
      peer = await FakeUser.create('00000000-0000-4000-8000-00000000000b');
      api.handles['CT-AAAA-0001'] = alice.id;
      api.keyBundles[alice.id] = await alice.keyBundle();
      api.keyBundles[peer.id] = await peer.keyBundle();
      bot = await CallTypeBot.start(
        apiBaseUrl: api.url,
        storePath: '${dir.path}/bot.store',
        storeKeyBase64: testStoreKey,
        transportFactory: (_, _) => hub,
        log: logs.add,
        sendRetryDelay: Duration.zero,
      );
      api.groups[groupId] = [alice.id, peer.id, bot.deviceId];
      api.memberFields[alice.id] = {'role': 'admin'};
      api.memberFields[peer.id] = {'isBot': true, 'userHandle': 'CT-PEER-0002'};
      api.groupDetails[groupId] = {
        'groupId': groupId,
        'botTalk': {'mode': 'all', 'maxBotTurns': 5},
      };
    });
    tearDown(() async {
      if (!turn.isClosed) await turn.close();
      await bot.close();
      await alice.close();
      await peer.close();
      await api.close();
      await dir.delete(recursive: true);
    });

    Future<HermesBridge> start({
      ProgressSettings progress = ProgressSettings.never,
    }) => runBridge(
      bot,
      allowedHandles: {'CT-AAAA-0001'},
      stream: stream,
      approve: approve,
      progress: progress,
      log: logs.add,
    );

    /// Every payload alice got since the last call, decrypted IN ORDER (the
    /// ratchet), from 1:1 or group sends.
    Future<List<Map<String, dynamic>>> aliceInbox() async {
      final sends = [
        for (final i in hub.invocations)
          if (i.method == 'SendReliableDirectFanout' ||
              i.method == 'SendReliableGroupFanout')
            i.args,
      ];
      final out = <Map<String, dynamic>>[];
      for (final call in sends.skip(readSoFar)) {
        out.add(
          await alice.readPayload(
            bot.deviceId,
            (call[3] as Map<String, String>)[alice.id]!,
          ),
        );
      }
      readSoFar = sends.length;
      return out;
    }

    int sends() => hub.invocations
        .where(
          (i) =>
              i.method == 'SendReliableDirectFanout' ||
              i.method == 'SendReliableGroupFanout',
        )
        .length;

    Future<void> say(
      FakeUser from,
      String text, {
      String? group,
      Map<String, dynamic> extra = const {},
    }) async => hub.deliver(
      await from.messageTo(
        bot.deviceId,
        api.botBundle,
        text,
        groupId: group,
        extra: extra,
      ),
    );

    test('fast answer: no progress message, one reply', () async {
      await start(
        progress: const ProgressSettings(after: Duration(milliseconds: 300)),
      );
      await say(alice, 'hi');
      await until(() => prompts.isNotEmpty);
      turn
        ..add(const HermesDelta('Hel'))
        ..add(const HermesCompleted('Hello'));
      await turn.close();
      await until(() => hub.calls('AcknowledgeMessage').isNotEmpty);
      final inbox = await aliceInbox();
      expect(inbox.single['body'], 'Hello');
      expect(inbox.single['type'], 'text');
    });

    test('slow turn: progress after the delay, throttled edits, the answer '
        'replaces the progress message', () async {
      await start(
        progress: const ProgressSettings(
          after: Duration(milliseconds: 50),
          editInterval: Duration(milliseconds: 250),
          maxEdits: 2,
        ),
      );
      await say(alice, 'build it');
      await until(() => prompts.isNotEmpty);
      await until(() => sends() == 1, reason: 'progress message');
      final progress = (await aliceInbox()).single;
      expect(progress['body'], 'Working on it...');

      // A burst of tool events: at most one edit per interval.
      for (var i = 0; i < 5; i++) {
        turn.add(
          HermesToolEvent(
            phase: 'started',
            toolName: 'terminal',
            preview: 'step $i',
          ),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(sends(), 1);
      await until(() => sends() == 2, reason: 'first throttled edit');
      final edit = (await aliceInbox()).single;
      expect(edit['type'], 'edit');
      expect(edit['editOf'], progress['id']);
      expect(edit['body'], 'Working on it... (step 5)\nterminal: step 4');

      // Max edits: one more allowed, then silence until the answer.
      turn.add(const HermesToolEvent(phase: 'started', toolName: 'web'));
      await until(() => sends() == 3, reason: 'second edit');
      turn.add(const HermesToolEvent(phase: 'started', toolName: 'browser'));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(sends(), 3);

      turn.add(const HermesCompleted('Built.'));
      await turn.close();
      await until(() => hub.calls('AcknowledgeMessage').isNotEmpty);
      final rest = await aliceInbox();
      expect(rest.last['type'], 'edit');
      expect(rest.last['editOf'], progress['id']);
      expect(rest.last['body'], 'Built.');
      // The answer replaced the progress: no extra text message.
      expect(rest.where((p) => p['type'] == 'text'), isEmpty);
    });

    test(
      'turn error with progress shown: the progress becomes the apology',
      () async {
        await start(
          progress: const ProgressSettings(after: Duration(milliseconds: 20)),
        );
        await say(alice, 'x');
        await until(() => sends() == 1);
        turn.add(const HermesError('model down'));
        await turn.close();
        await until(() => hub.calls('AcknowledgeMessage').isNotEmpty);
        final inbox = await aliceInbox();
        expect(inbox.last['type'], 'edit');
        expect(inbox.last['body'], startsWith('Sorry, something went wrong'));
        expect(inbox, hasLength(2));
      },
    );

    test('approval: buttons sent; owner press approves and edits the message '
        'while the turn waits', () async {
      await start();
      await say(alice, 'clean build dir');
      await until(() => prompts.isNotEmpty);
      turn.add(
        const HermesApprovalRequest(
          runId: 'run_abc',
          requestId: 'req_def',
          command: 'rm -rf build',
          description: 'recursive delete',
        ),
      );
      await until(() => sends() == 1);
      final request = (await aliceInbox()).single;
      expect(request['body'], contains('rm -rf build'));
      final buttons = (request['actions'] as List).cast<Map>();
      expect(buttons.map((b) => b['label']), [
        'Approve once',
        'Approve for session',
        'Deny',
      ]);
      final once = buttons.first['id'] as String;
      expect(once, matches(RegExp(r'^approve:[0-9a-f]{12}:once$')));
      expect(buttons.last['id'], once.replaceFirst(':once', ':deny'));

      // The conversation handler is still inside the turn; the press must
      // get through anyway.
      await say(
        alice,
        'Approve once',
        extra: {
          'replyTo': {
            'id': request['id'],
            'senderId': bot.deviceId,
            'preview': 'x',
          },
          'action': {'messageId': request['id'], 'id': once},
        },
      );
      await until(() => approvals.isNotEmpty);
      expect(approvals.single, ('run_abc', 'req_def', 'once'));
      await until(() => sends() == 2);
      final edited = (await aliceInbox()).single;
      expect(edited['type'], 'edit');
      expect(edited['editOf'], request['id']);
      expect(edited['actions'], isEmpty);
      expect(edited['body'], endsWith('Approved once by CT-AAAA-0001.'));

      turn.add(const HermesCompleted('Cleaned.'));
      await turn.close();
      await until(() => hub.calls('AcknowledgeMessage').length == 2);
      expect((await aliceInbox()).single['body'], 'Cleaned.');
    });

    test('approval left open when the turn ends loses its buttons', () async {
      await start();
      await say(alice, 'x');
      await until(() => prompts.isNotEmpty);
      turn.add(
        const HermesApprovalRequest(
          runId: 'r',
          requestId: 'q',
          command: 'c',
          choices: ['once', 'deny'],
        ),
      );
      await until(() => sends() == 1);
      final request = (await aliceInbox()).single;
      expect((request['actions'] as List).map((b) => (b as Map)['label']), [
        'Approve once',
        'Deny',
      ]);
      turn.add(const HermesCompleted('Timed out waiting.'));
      await turn.close();
      await until(() => hub.calls('AcknowledgeMessage').isNotEmpty);
      final rest = await aliceInbox();
      final closed = rest.firstWhere((p) => p['type'] == 'edit');
      expect(closed['editOf'], request['id']);
      expect(closed['actions'], isEmpty);
      expect(closed['body'], endsWith('No longer pending.'));
    });

    test('a non-owner press is refused, nothing is approved', () async {
      await start();
      await say(alice, '@${bot.handle} deploy', group: groupId);
      await until(() => prompts.isNotEmpty);
      turn.add(
        const HermesApprovalRequest(runId: 'r', requestId: 'q', command: 'c'),
      );
      await until(() => sends() == 1);
      final request = (await aliceInbox()).single;
      expect(request['groupId'], groupId);
      final once = ((request['actions'] as List).first as Map)['id'];

      // A peer bot admitted by the group's bot-talk setting presses it.
      await say(
        peer,
        'Approve once',
        group: groupId,
        extra: {
          'replyTo': {
            'id': request['id'],
            'senderId': bot.deviceId,
            'preview': 'x',
          },
          'action': {'messageId': request['id'], 'id': once},
        },
      );
      await until(() => sends() == 2);
      final refusal = (await aliceInbox()).single;
      expect(refusal['body'], approvalOwnerOnlyNotice);
      expect(approvals, isEmpty);

      turn.add(const HermesCompleted('ok'));
      await turn.close();
    });

    test(
      'quote context and plain button presses reach Hermes as text',
      () async {
        await start();
        await say(
          alice,
          'yes, do that',
          extra: {
            'replyTo': {
              'id': 'm0',
              'senderId': bot.deviceId,
              'preview': 'Shall I restart nginx?',
            },
          },
        );
        await until(() => prompts.isNotEmpty);
        expect(
          prompts.single,
          '[from CT-AAAA-0001]: [Replying to: "Shall I restart nginx?"]\n'
          'yes, do that',
        );
        turn.add(const HermesCompleted('Restarted.'));
        await turn.close();
        await until(() => hub.calls('AcknowledgeMessage').length == 1);

        // A press on a message this bot did not send with buttons.
        await say(
          alice,
          'Yes',
          extra: {
            'action': {'messageId': 'someone-else', 'id': 'yes'},
          },
        );
        await until(() => prompts.length == 2);
        expect(prompts.last, '[from CT-AAAA-0001]: [Button: Yes]');
        turn.add(const HermesCompleted('ok'));
        await turn.close();
      },
    );
  });
}
