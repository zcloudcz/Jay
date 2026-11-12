import 'dart:io';

import 'package:a2a_bridge/a2a_bridge.dart';
import 'package:a2a_bridge/src/jay_glue.dart';
import 'package:calltype_bot/calltype_bot.dart';
import 'package:test/test.dart';

import '../../calltype_bot/test/helpers.dart';
import 'support/fake_a2a_server.dart';

/// The glue on the real bot runtime with acknowledgement reactions (spec
/// 2026-11-11-bot-ack-reactions R4: defaults only, no directive).
void main() {
  late Directory dir;
  late FakeA2aServer server;
  late A2aClient client;
  late FakeApi api;
  late FakeHub hub;
  late FakeUser owner;
  late FakeUser stranger;
  late CallTypeBot bot;
  var agentText = 'Hello';
  var agentState = 'TASK_STATE_COMPLETED';

  Future<void> start({required bool ack}) async {
    final bridge = A2aBridge(
      client: client,
      state: await StateStore.open('${dir.path}/state.json'),
      card: await client.discover(),
      timeout: const Duration(seconds: 5),
      pollInterval: const Duration(milliseconds: 20),
    );
    await runJayGlue(
      bot,
      bridge: bridge,
      allowedIds: {owner.id.toLowerCase(): 'CT-AAAA-0001'},
      ackReactions: ack,
      log: (_) {},
    );
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('a2a_ack_test');
    server = await FakeA2aServer.start();
    server.cards['/.well-known/agent-card.json'] = v1Card('${server.url}/');
    agentText = 'Hello';
    agentState = 'TASK_STATE_COMPLETED';
    server.onRpc = (_) =>
        ok({'task': v1Task('t', agentState, text: agentText)});
    client = A2aClient(agentUrl: server.url);
    api = await FakeApi.start();
    hub = FakeHub();
    owner = await FakeUser.create('00000000-0000-4000-8000-00000000000a');
    stranger = await FakeUser.create('00000000-0000-4000-8000-00000000000e');
    api.keyBundles[owner.id] = await owner.keyBundle();
    api.keyBundles[stranger.id] = await stranger.keyBundle();
    bot = await CallTypeBot.start(
      apiBaseUrl: api.url,
      storePath: '${dir.path}/bot.store',
      storeKeyBase64: testStoreKey,
      transportFactory: (_, _) => hub,
      log: (_) {},
      sendRetryDelay: Duration.zero,
    );
  });

  tearDown(() async {
    await bot.close();
    await owner.close();
    await stranger.close();
    await api.close();
    client.close();
    await server.close();
    await dir.delete(recursive: true);
  });

  Future<List<String>> transcript() async => [
    for (final call in hub.calls('SendReliableDirectFanout'))
      switch (await owner.readPayload(
        bot.deviceId,
        (call[3] as Map<String, String>)[owner.id]!,
      )) {
        final p when p['type'] == reactionType =>
          'react:${ReactionPayload.decode(p['body'])!.targetId}:'
              '${ReactionPayload.decode(p['body'])!.emoji}',
        final p => p['body'] as String,
      },
  ];

  Future<String> say(FakeUser from, String text) async {
    final before = hub.calls('AcknowledgeMessage').length;
    final m = await from.messageTo(bot.deviceId, api.botBundle, text);
    hub.deliver(m);
    await until(() => hub.calls('AcknowledgeMessage').length == before + 1);
    return m['messageId'] as String;
  }

  test('answered: 👀, the answer, ✅', () async {
    await start(ack: true);
    final id = await say(owner, 'ahoj');
    expect(await transcript(), ['react:$id:👀', 'Hello', 'react:$id:✅']);
  });

  test('a failed task: the error text and ❌', () async {
    await start(ack: true);
    agentState = 'TASK_STATE_FAILED';
    agentText = 'disk full';
    final id = await say(owner, 'x');
    expect(await transcript(), [
      'react:$id:👀',
      'The agent failed: disk full',
      'react:$id:❌',
    ]);
  });

  test('a directive is not special here: posted as text, ✅', () async {
    await start(ack: true);
    agentText = '[react:👍]';
    final id = await say(owner, 'díky');
    expect(await transcript(), ['react:$id:👀', '[react:👍]', 'react:$id:✅']);
  });

  test('a stranger gets nothing; off: only the answer', () async {
    await start(ack: false);
    await say(stranger, 'hi');
    expect(hub.calls('SendReliableDirectFanout'), isEmpty);
    await say(owner, 'ahoj');
    expect(await transcript(), ['Hello']);
  });

  test('reactions never start a turn', () async {
    await start(ack: true);
    final before = hub.calls('AcknowledgeMessage').length;
    final calls = server.calls.length;
    final sent = hub.calls('SendReliableDirectFanout').length;
    hub.deliver(
      await owner.messageTo(
        bot.deviceId,
        api.botBundle,
        const ReactionPayload(targetId: 'm1', emoji: '👍').encode(),
        extra: {'type': reactionType},
      ),
    );
    await until(() => hub.calls('AcknowledgeMessage').length == before + 1);
    expect(server.calls, hasLength(calls));
    expect(hub.calls('SendReliableDirectFanout'), hasLength(sent));
  });
}
