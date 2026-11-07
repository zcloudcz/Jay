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
      // Generous: the first request of the run pays for JIT and a busy
      // machine (300 ms failed under a parallel test load). Only the
      // timeout test uses a short one, on its own client.
      client = HermesClient(
        baseUrl: hermes.url,
        apiKey: 'key',
        timeout: const Duration(seconds: 10),
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
      final short = HermesClient(
        baseUrl: hermes.url,
        apiKey: 'key',
        timeout: const Duration(milliseconds: 300),
        retryDelay: Duration.zero,
      );
      addTearDown(short.close);
      await expectLater(
        short.ask('hi', conversationId: 'c'),
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

    // What the backend answers; null = 'answer to <prompt>'.
    String? reply;
    var delay = Duration.zero;

    Future<String> backend(String text, {required String conversationId}) async {
      backendCalls.add('$conversationId: $text');
      await Future<void>.delayed(delay);
      return reply ?? 'answer to $text';
    }

    setUp(() async {
      backendCalls.clear();
      logs.clear();
      reply = null;
      delay = Duration.zero;
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

      // The first owner message of a conversation carries the directive
      // hint once; later ones do not.
      expect(backendCalls, ['${alice.id}: $reactDirectiveHint\n[from CT-AAAA-0001]: hi']);
      final sent = hub.calls('SendReliableDirectFanout').single;
      expect(
        await alice.read(bot.deviceId, (sent[3] as Map<String, String>)[alice.id]!),
        'answer to $reactDirectiveHint\n[from CT-AAAA-0001]: hi',
      );
      hub.deliver(await alice.messageTo(bot.deviceId, api.botBundle, 'again'));
      await until(() => hub.calls('AcknowledgeMessage').length == 2);
      expect(backendCalls.last, '${alice.id}: [from CT-AAAA-0001]: again');
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
      expect(hub.calls('SendReliableDirectFanout'), isEmpty);
      expect(hub.calls('TypingIndicator'), isEmpty);
      expect(logs.join('\n'), contains('CT-SOME-BODY is unknown'));
    });

    test('empty allowlist: replies to nobody and logs how to allow', () async {
      await runBridge(bot, allowedHandles: {}, backend: backend, log: logs.add);
      hub.deliver(await alice.messageTo(bot.deviceId, api.botBundle, 'hello?'));
      await until(() => hub.calls('AcknowledgeMessage').isNotEmpty);

      expect(backendCalls, isEmpty);
      expect(hub.calls('SendReliableDirectFanout'), isEmpty);
      expect(logs.join('\n'), contains('Set ALLOWED_HANDLES='));
    });

    group('peer bots (group bot-talk setting)', () {
      const groupId = '00000000-0000-4000-8000-0000000000c0';
      late FakeUser peer;
      late FakeUser stranger;
      late FakeUser other;
      var clock = DateTime.utc(2026, 11, 5, 12);

      void setTalk(Map<String, dynamic>? botTalk) => botTalk == null
          ? api.groupDetails.remove(groupId)
          : api.groupDetails[groupId] = {'groupId': groupId, 'botTalk': botTalk};

      setUp(() async {
        clock = DateTime.utc(2026, 11, 5, 12);
        peer = await FakeUser.create('00000000-0000-4000-8000-00000000000b');
        stranger = await FakeUser.create('00000000-0000-4000-8000-00000000000c');
        other = await FakeUser.create('00000000-0000-4000-8000-00000000000d');
        api.handles['CT-PEER-0002'] = peer.id;
        api.handles['CT-OTHR-0003'] = other.id;
        api.handles['CT-STRA-0004'] = stranger.id;
        api.keyBundles[alice.id] = await alice.keyBundle();
        api.keyBundles[peer.id] = await peer.keyBundle();
        api.keyBundles[stranger.id] = await stranger.keyBundle();
        api.keyBundles[other.id] = await other.keyBundle();
        api.groups[groupId] = [alice.id, peer.id, other.id, bot.deviceId];
        api.memberFields[alice.id] = {'role': 'admin', 'userHandle': 'CT-AAAA-0001'};
        api.memberFields[peer.id] = {'isBot': true, 'userHandle': 'CT-PEER-0002'};
        api.memberFields[other.id] = {'isBot': true};
        setTalk({'mode': 'all', 'maxBotTurns': 2, 'pauseMinutes': 30});
      });
      tearDown(() async {
        await peer.close();
        await stranger.close();
        await other.close();
      });

      Future<HermesBridge> start({Set<String> peers = const {}, int cap = 50}) =>
          runBridge(
            bot,
            allowedHandles: {'CT-AAAA-0001'},
            peerHandles: peers,
            peerTurnsCap: cap,
            now: () => clock,
            backend: backend,
            log: logs.add,
          );

      // Sends [text] mentioning the bot and waits until it was acknowledged
      // (the handler, including its replies, has finished by then).
      Future<void> say(FakeUser from, String text, {String? group = groupId}) async {
        final before = hub.calls('AcknowledgeMessage').length;
        hub.deliver(
          await from.messageTo(
            bot.deviceId,
            api.botBundle,
            '@${bot.handle} $text',
            groupId: group,
          ),
        );
        await until(() => hub.calls('AcknowledgeMessage').length == before + 1);
      }

      test('mode all, owner admin: backend gets the "(bot)" label', () async {
        await start();
        await say(peer, 'ping');
        expect(backendCalls, ['$groupId: [from CT-PEER-0002 (bot)]: @${bot.handle} ping$botSilenceHint']);
        expect(hub.calls('SendReliableGroupFanout'), hasLength(1));
      });

      test('[SILENT] answer to a bot: nothing is sent, the turn still counts', () async {
        await start();
        reply = '  [silent]\n';
        await say(peer, 'bye');
        expect(backendCalls, hasLength(1));
        expect(hub.calls('SendReliableGroupFanout'), isEmpty);
        expect(logs.join('\n'), contains('silent, nothing sent'));
      });

      test('empty answer to a bot: no apology either', () async {
        await start();
        reply = '   ';
        await say(peer, 'bye');
        expect(hub.calls('SendReliableGroupFanout'), isEmpty);
      });

      test('slow answer to a bot: no progress message, only the answer', () async {
        await runBridge(
          bot,
          allowedHandles: {'CT-AAAA-0001'},
          now: () => clock,
          backend: backend,
          progress: const ProgressSettings(after: Duration(milliseconds: 10)),
          log: logs.add,
        );
        delay = const Duration(milliseconds: 200);
        await say(peer, 'slow');
        final sent = hub.calls('SendReliableGroupFanout');
        expect(sent, hasLength(1));
        final body = (sent.single[3] as Map<String, String>)[alice.id]!;
        expect(await alice.read(bot.deviceId, body), startsWith('answer to'));
      });

      test('[SILENT] answer to the owner: nothing is sent', () async {
        await start();
        reply = '[SILENT]';
        await say(alice, 'quiet please');
        expect(hub.calls('SendReliableGroupFanout'), isEmpty);
      });

      test('human message gets the plain handle label', () async {
        await start();
        await say(alice, 'hi');
        expect(backendCalls, [
          '$groupId: $reactDirectiveHint\n[from CT-AAAA-0001]: @${bot.handle} hi',
        ]);
      });

      // Every refusal below is silent: no backend call, no notice.
      final refusals = <String, (Map<String, dynamic>?, void Function(FakeApi), Set<String>)>{
        'old server without botTalk (= off)': (null, (_) {}, {}),
        'mode off': ({'mode': 'off'}, (_) {}, {}),
        'owner is not an admin of the group': (
          {'mode': 'all'},
          (api) => api.memberFields['00000000-0000-4000-8000-00000000000a'] = {'role': 'member'},
          {},
        ),
        'selected without this bot': (
          {
            'mode': 'selected',
            'allowedBotDeviceIds': ['00000000-0000-4000-8000-00000000000b'],
          },
          (_) {},
          {},
        ),
        'PEER_BOT_HANDLES names another bot (narrows)': ({'mode': 'all'}, (_) {}, {'CT-OTHR-0003'}),
      };
      refusals.forEach((name, c) {
        test('refused: $name', () async {
          setTalk(c.$1);
          c.$2(api);
          await start(peers: c.$3);
          await say(peer, 'ping');
          expect(backendCalls, isEmpty);
          expect(hub.calls('SendReliableGroupFanout'), isEmpty);
        });
      });

      test('selected with both bots listed is allowed', () async {
        setTalk({
          'mode': 'selected',
          'allowedBotDeviceIds': [peer.id, bot.deviceId],
        });
        await start(peers: {'CT-PEER-0002'});
        await say(peer, 'ping');
        expect(backendCalls, hasLength(1));
      });

      test('peer in a 1:1 chat is ignored', () async {
        await start();
        await say(peer, 'psst', group: null);
        expect(backendCalls, isEmpty);
        expect(hub.calls('SendReliableDirectFanout'), isEmpty);
      });

      test('sender that is not a bot member is still dropped', () async {
        await start();
        await say(stranger, 'let me in');
        expect(backendCalls, isEmpty);
        expect(hub.calls('SendReliableGroupFanout'), isEmpty);
      });

      test('limit: one notice, then silence; pause; a human message resets', () async {
        await start();
        await say(peer, 'one');
        await say(peer, 'two');
        expect(backendCalls, hasLength(2));
        final answers = hub.calls('SendReliableGroupFanout').length;

        await say(peer, 'three'); // over the limit -> notice, no backend
        expect(backendCalls, hasLength(2));
        expect(hub.calls('SendReliableGroupFanout'), hasLength(answers + 1));
        final notice = hub.calls('SendReliableGroupFanout').last;
        final body = (notice[3] as Map<String, String>)[alice.id]!;
        expect(await alice.read(bot.deviceId, body), botLimitNotice);
        expect(botLimitNotice, 'Bot limit reached, waiting for a human.');

        await say(peer, 'four'); // silent
        clock = clock.add(const Duration(minutes: 29));
        await say(peer, 'five'); // still in the pause: silent
        expect(backendCalls, hasLength(2));
        expect(hub.calls('SendReliableGroupFanout'), hasLength(answers + 1));

        clock = clock.add(const Duration(minutes: 1));
        await say(peer, 'six'); // pause over: a new exchange
        expect(backendCalls, hasLength(3));

        await say(peer, 'seven');
        await say(peer, 'eight'); // limit again -> second exchange's notice
        await say(alice, 'carry on'); // human resets at once
        await say(peer, 'nine');
        expect(backendCalls.last, contains('nine'));
      });

      group('local send', () {
        test('1:1 to an owner: sent, the owner can read it', () async {
          final bridge = await start();
          expect(await bridge.sendFromLocal('ct-aaaa-0001', 'nightly ok'), SendOutcome.sent);
          final sent = hub.calls('SendReliableDirectFanout').single;
          expect(
            await alice.read(bot.deviceId, (sent[3] as Map<String, String>)[alice.id]!),
            'nightly ok',
          );
        });

        test('1:1 to anyone else (human or bot) is forbidden', () async {
          final bridge = await start();
          expect(await bridge.sendFromLocal('CT-STRA-0004', 'x'), SendOutcome.forbidden);
          expect(await bridge.sendFromLocal('CT-PEER-0002', 'x'), SendOutcome.forbidden);
          expect(hub.calls('SendReliableDirectFanout'), isEmpty);
        });

        test('group: member -> sent; counts as bot turns; foreign group forbidden', () async {
          final bridge = await start();
          expect(await bridge.sendFromLocal(groupId, 'deploy 28f5070'), SendOutcome.sent);
          expect(await bridge.sendFromLocal(groupId, 'done'), SendOutcome.sent);
          expect(await bridge.sendFromLocal(groupId, 'again'), SendOutcome.forbidden);
          expect(hub.calls('SendReliableGroupFanout'), hasLength(2));
          // The exchange is used up by our own posts: a peer turn is dropped
          // (the notice was the 403 to the caller).
          await say(peer, 'reply');
          expect(backendCalls, isEmpty);

          const foreign = '00000000-0000-4000-8000-0000000000c1';
          api.groups[foreign] = [alice.id, peer.id];
          expect(await bridge.sendFromLocal(foreign, 'x'), SendOutcome.forbidden);
          expect(
            await bridge.sendFromLocal('00000000-0000-4000-8000-0000000000c9', 'x'),
            SendOutcome.forbidden,
          );
        });

        test('long text is split, one turn per request', () async {
          final bridge = await start();
          final text = List.filled(3, 'x' * (maxReplyChars - 10)).join(' ');
          expect(await bridge.sendFromLocal(groupId, text), SendOutcome.sent);
          expect(hub.calls('SendReliableGroupFanout'), hasLength(3));
          expect(await bridge.sendFromLocal(groupId, 'second turn'), SendOutcome.sent);
        });

        test('over HTTP: 202 and delivered', () async {
          final bridge = await start();
          final server = (await startSendEndpoint(
            key: 'k3y',
            port: 0,
            send: bridge.sendFromLocal,
            log: logs.add,
          ))!;
          addTearDown(() => server.close(force: true));
          final client = HttpClient();
          addTearDown(client.close);
          final request = await client.post('127.0.0.1', server.port, '/send');
          request.headers.set('authorization', 'Bearer k3y');
          request.write(jsonEncode({'to': 'CT-AAAA-0001', 'text': 'hello from cron'}));
          final response = await request.close();
          await response.drain<void>();
          expect(response.statusCode, 202);
          expect(hub.calls('SendReliableDirectFanout'), hasLength(1));
        });

        group('to a channel', () {
          const channelId = '00000000-0000-4000-8000-0000000000d0';
          setUp(() {
            final channel = {
              'channelId': channelId,
              'handle': 'CH-NEWS-0001',
              'name': 'News',
              'role': 'publisher',
            };
            api.channels[channelId] = channel;
            api.channels['CH-NEWS-0001'] = channel;
          });

          test('handle or id: one post each; NOT a group bot turn', () async {
            final bridge = await start();
            expect(
              await bridge.sendFromLocal('channel:ch-news-0001', 'Issue #1'),
              SendOutcome.sent,
            );
            expect(
              await bridge.sendFromLocal('CHANNEL: $channelId', 'Issue #2'),
              SendOutcome.sent,
            );
            expect(api.channelPosts.map((p) => p.body['body']), ['Issue #1', 'Issue #2']);
            expect(api.channelPosts.every((p) => p.channelId == channelId), isTrue);
            expect(logs.where((l) => l.contains('posted')), hasLength(2));
            // The group exchange (maxBotTurns 2) is untouched by the posts.
            expect(await bridge.sendFromLocal(groupId, 'a'), SendOutcome.sent);
            expect(await bridge.sendFromLocal(groupId, 'b'), SendOutcome.sent);
            expect(await bridge.sendFromLocal(groupId, 'c'), SendOutcome.forbidden);
          });

          test('server refusals map to outcomes, with a log line', () async {
            final bridge = await start();
            api.channelPostFailures.addAll([
              (403, {'error': 'Suspended.', 'code': 'channel_suspended'}),
              (429, {'error': 'Limit.', 'code': 'bot_post_limit'}),
              (403, null), // not a publisher: bodyless role 403
              (503, null),
            ]);
            Future<SendOutcome> post() => bridge.sendFromLocal('channel:CH-NEWS-0001', 'x');
            expect(await post(), SendOutcome.channelSuspended);
            expect(await post(), SendOutcome.rateLimited);
            expect(await post(), SendOutcome.forbidden);
            expect(await post(), SendOutcome.failed);
            expect(
              await bridge.sendFromLocal('channel:CH-NOPE-0000', 'x'),
              SendOutcome.badTarget,
            );
            expect(api.channelPosts, isEmpty);
            final log = logs.join('\n');
            expect(log, contains('channel_suspended'));
            expect(log, contains('bot_post_limit'));
          });

          test('malformed target or too long text: refused without a request', () async {
            final bridge = await start();
            final before = api.requests.where((r) => r.contains('/channels')).length;
            for (final to in ['channel:', 'channel:../groups', 'channel:CT-AAAA-0001']) {
              expect(await bridge.sendFromLocal(to, 'x'), SendOutcome.badTarget, reason: to);
            }
            expect(
              await bridge.sendFromLocal(
                'channel:CH-NEWS-0001',
                'x' * (channelPostMaxChars + 1),
              ),
              SendOutcome.textTooLong,
            );
            expect(api.requests.where((r) => r.contains('/channels')).length, before);
          });

          test('over HTTP: 202, 403, 429, 400', () async {
            final bridge = await start();
            final server = (await startSendEndpoint(
              key: 'k3y',
              port: 0,
              send: bridge.sendFromLocal,
              log: logs.add,
            ))!;
            addTearDown(() => server.close(force: true));
            final client = HttpClient();
            addTearDown(client.close);
            // Status + body as one string: records compare maps by identity.
            Future<String> call(String to) async {
              final request = await client.post('127.0.0.1', server.port, '/send');
              request.headers.set('authorization', 'Bearer k3y');
              request.write(jsonEncode({'to': to, 'text': 'newsletter'}));
              final response = await request.close();
              return '${response.statusCode} ${await utf8.decodeStream(response)}';
            }

            api.channelPostFailures.addAll([
              (403, {'error': 'Suspended.', 'code': 'channel_suspended'}),
              (429, {'error': 'Limit.', 'code': 'bot_post_limit'}),
            ]);
            expect(await call('channel:CH-NEWS-0001'), '403 {"error":"channel_suspended"}');
            expect(await call('channel:CH-NEWS-0001'), '429 {"error":"bot_post_limit"}');
            expect(await call('channel:CH-NEWS-0001'), '202 {"status":"sent"}');
            expect(await call('channel:nonsense'), '400 {"error":"bad_target"}');
            expect(api.channelPosts, hasLength(1));
          });
        });
      });
    });
  });
}
