import 'dart:convert';
import 'dart:io';

import 'package:calltype_bot/calltype_bot.dart';
import 'package:llm_bridge/llm_bridge.dart';
import 'package:llm_bridge/src/jay_glue.dart';
import 'package:test/test.dart';

import '../../calltype_bot/test/helpers.dart';
import 'support/fakes.dart';

/// Acknowledgement reactions on the real runtime (spec
/// 2026-11-11-bot-ack-reactions): 👀 before the turn, then ✅ / 👍 / ❌ or
/// the model's [react:EMOJI]; nothing for ignored messages.
void main() {
  const groupId = '00000000-0000-4000-8000-0000000000c1';
  late Directory dir;
  late FakeApi api;
  late FakeHub hub;
  late FakeUser owner;
  late FakeUser peer;
  late CallTypeBot bot;
  late FakeProvider provider;

  Future<void> start({required bool ack}) async {
    final store = await HistoryStore.open(
      '${dir.path}/bot.store.llm',
      base64Decode(testStoreKey),
      cap: 20,
    );
    await runJayGlue(
      bot,
      bridge: LlmBridge(
        provider: provider,
        history: store,
        displayName: 'Pepa',
        systemPrompt: 's',
        progressAfter: Duration.zero,
      ),
      allowedIds: await resolveAllowedHandles({
        'CT-AAAA-0001',
      }, bot.deviceIdForHandle),
      ackReactions: ack,
      log: (_) {},
    );
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('llm_ack_test');
    api = await FakeApi.start();
    owner = await FakeUser.create('00000000-0000-4000-8000-00000000000a');
    peer = await FakeUser.create('00000000-0000-4000-8000-00000000000b');
    api.keyBundles[owner.id] = await owner.keyBundle();
    api.keyBundles[peer.id] = await peer.keyBundle();
    api.handles['CT-AAAA-0001'] = owner.id;
    hub = FakeHub();
    bot = await CallTypeBot.start(
      apiBaseUrl: api.url,
      storePath: '${dir.path}/bot.store',
      storeKeyBase64: testStoreKey,
      displayName: 'Pepa',
      transportFactory: (_, _) => hub,
      log: (_) {},
      sendRetryDelay: Duration.zero,
    );
    provider = FakeProvider();
    api.groups[groupId] = [owner.id, peer.id, bot.deviceId];
    api.memberFields[peer.id] = {'isBot': true, 'userHandle': 'CT-PEER-0002'};
  });

  tearDown(() async {
    await bot.close();
    await owner.close();
    await peer.close();
    await api.close();
    await dir.delete(recursive: true);
  });

  /// What the owner got, in order: `react:<target>:<emoji>` or the text.
  Future<List<String>> transcript(String method) async => [
    for (final call in hub.calls(method))
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

  Future<String> say(FakeUser from, String text, {String? group}) async {
    final before = hub.calls('AcknowledgeMessage').length;
    final m = await from.messageTo(
      bot.deviceId,
      api.botBundle,
      group == null ? text : '@${bot.handle} $text',
      groupId: group,
    );
    hub.deliver(m);
    await until(() => hub.calls('AcknowledgeMessage').length == before + 1);
    return m['messageId'] as String;
  }

  test('ahoj: 👀, the answer, ✅', () async {
    await start(ack: true);
    provider.scripts.add(() => answer(['Ahoj!']));
    final id = await say(owner, 'ahoj');
    expect(await transcript('SendReliableDirectFanout'), [
      'react:$id:👀',
      'Ahoj!',
      'react:$id:✅',
    ]);
    expect(provider.calls.single.system, contains('[react:EMOJI]'));
  });

  test('díky: 👀 replaced by 👍, no text', () async {
    await start(ack: true);
    provider.scripts.add(() => answer(['[react:👍]']));
    final id = await say(owner, 'díky');
    expect(await transcript('SendReliableDirectFanout'), [
      'react:$id:👀',
      'react:$id:👍',
    ]);
  });

  test('a provider error: the error text and ❌', () async {
    await start(ack: true);
    provider.scripts.add(() => Stream.error(const LlmException('down')));
    final id = await say(owner, 'x');
    final t = await transcript('SendReliableDirectFanout');
    expect(t.first, 'react:$id:👀');
    expect(t[1], startsWith('Sorry, I could not answer'));
    expect(t.last, 'react:$id:❌');
  });

  test('/help: answered locally, ✅', () async {
    await start(ack: true);
    final id = await say(owner, '/help');
    final t = await transcript('SendReliableDirectFanout');
    expect(t.first, 'react:$id:👀');
    expect(t.last, 'react:$id:✅');
    expect(provider.calls, isEmpty);
  });

  test('off: only the answer; a model directive still reacts', () async {
    await start(ack: false);
    provider.scripts.add(() => answer(['Ahoj!']));
    await say(owner, 'ahoj');
    provider.scripts.add(() => answer(['[react:👍]']));
    final id = await say(owner, 'díky');
    expect(await transcript('SendReliableDirectFanout'), [
      'Ahoj!',
      'react:$id:👍',
    ]);
  });

  group('bots in a group', () {
    void setTalk(String mode) => api.groupDetails[groupId] = {
      'groupId': groupId,
      'botTalk': {'mode': mode, 'maxBotTurns': 1, 'pauseMinutes': 30},
    };

    test('a handled bot message gets 👀 and ✅; the limit notice, bot '
        'talk off and a bot\'s reaction get nothing', () async {
      setTalk('all');
      await start(ack: true);
      provider.scripts.add(() => answer(['pong']));
      final id = await say(peer, 'ping', group: groupId);
      expect(await transcript('SendReliableGroupFanout'), [
        'react:$id:👀',
        'pong',
        'react:$id:✅',
      ]);
      await say(peer, 'again', group: groupId); // limit 1: the notice only
      expect(hub.calls('SendReliableGroupFanout'), hasLength(4));
      // The peer reacts to the bot's answer: no turn, no reaction.
      final answerId = hub.calls('SendReliableGroupFanout')[1][1] as String;
      final before = hub.calls('AcknowledgeMessage').length;
      hub.deliver(
        await peer.messageTo(
          bot.deviceId,
          api.botBundle,
          ReactionPayload(targetId: answerId, emoji: '👍').encode(),
          groupId: groupId,
          extra: {'type': reactionType},
        ),
      );
      await until(() => hub.calls('AcknowledgeMessage').length == before + 1);
      setTalk('off');
      hub.push('GroupChanged', {'groupId': groupId});
      await say(peer, 'ping 3', group: groupId);
      expect(provider.calls, hasLength(1));
      expect(hub.calls('SendReliableGroupFanout'), hasLength(4));
    });
  });
}
