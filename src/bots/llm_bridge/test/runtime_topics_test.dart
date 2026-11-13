import 'dart:convert';
import 'dart:io';

import 'package:calltype_bot/calltype_bot.dart';
import 'package:llm_bridge/llm_bridge.dart';
import 'package:llm_bridge/src/jay_glue.dart';
import 'package:test/test.dart';

import '../../calltype_bot/test/helpers.dart';
import 'support/fakes.dart';

/// Group topics through the REAL runtime (spec 2026-11-13-group-topics
/// T2-T4): topic, context and "reply without mention" end to end.
void main() {
  const groupId = '00000000-0000-4000-8000-0000000000c0';
  late Directory dir;
  late FakeApi api;
  late FakeHub hub;
  late FakeUser owner;
  late FakeUser member;
  late FakeUser peer;
  late CallTypeBot bot;
  late FakeProvider provider;
  late HistoryStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('llm_runtime_topics_test');
    api = await FakeApi.start();
    owner = await FakeUser.create('00000000-0000-4000-8000-00000000000a');
    member = await FakeUser.create('00000000-0000-4000-8000-00000000000b');
    peer = await FakeUser.create('00000000-0000-4000-8000-0000000000d1');
    for (final u in [owner, member, peer]) {
      api.keyBundles[u.id] = await u.keyBundle();
    }
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
    api.groups[groupId] = [owner.id, member.id, peer.id, bot.deviceId];
    api.memberFields[owner.id] = {'userHandle': 'CT-AAAA-0001'};
    api.memberFields[member.id] = {
      'userHandle': 'CT-BBBB-0002',
      'role': 'admin',
    };
    api.memberFields[peer.id] = {'isBot': true, 'userHandle': 'CT-PEER-0001'};
    provider = FakeProvider();
    store = await HistoryStore.open(
      '${dir.path}/bot.store.llm',
      base64Decode(testStoreKey),
      cap: 20,
    );
    final allowed = await resolveAllowedHandles({
      'CT-AAAA-0001',
    }, bot.deviceIdForHandle);
    await runJayGlue(
      bot,
      bridge: LlmBridge(
        provider: provider,
        history: store,
        displayName: 'Pepa',
        systemPrompt: 's',
        progressAfter: Duration.zero,
      ),
      allowedIds: allowed,
      ackReactions: false,
      log: (_) {},
    );
  });

  tearDown(() async {
    await bot.close();
    for (final u in [owner, member, peer]) {
      await u.close();
    }
    await api.close();
    await dir.delete(recursive: true);
  });

  void settings({bool readAll = false, bool withoutMention = false}) =>
      api.groupDetails[groupId] = {
        'groupId': groupId,
        'botTalk': {
          'mode': 'off',
          'botsReadAll': readAll,
          'replyWithoutMention': withoutMention,
        },
        'topic': {'version': 3, 'updatedBy': member.id},
      };

  Future<Map<String, dynamic>> text(FakeUser u, String body) =>
      u.messageTo(bot.deviceId, api.botBundle, body, groupId: groupId);

  int acks() => hub.calls('AcknowledgeMessage').length;

  test('T2: the admins\' topic reaches the system prompt', () async {
    settings();
    provider.scripts.add(() => answer(['ok']));
    // A non-owner admin sets it; the bot serves the group (owner inside).
    hub.deliver(
      await member.messageTo(
        bot.deviceId,
        api.botBundle,
        jsonEncode({'topic': 'Brno trip', 'version': 3}),
        groupId: groupId,
        extra: const {'type': groupTopicType},
      ),
    );
    hub.deliver(await text(owner, '@Pepa plan?'));
    await until(() => acks() == 2);
    expect(provider.calls.single.system, contains('<<<\nBrno trip\n>>>'));
  });

  test(
    'T3: unaddressed messages and refused bots become context, unanswered',
    () async {
      settings(readAll: true);
      provider.scripts.add(() => answer(['he says hi']));
      hub.deliver(await text(member, 'hi all'));
      hub.deliver(await text(peer, '@Pepa bot here')); // bot talk is off
      hub.deliver(await text(owner, '@Pepa what did they say?'));
      await until(() => acks() == 3);
      final call = provider.calls.single;
      expect(call.conversation.map((t) => t.text), [
        '[group context from CT-BBBB-0002] hi all',
        '[group context from CT-PEER-0001 (bot)] @Pepa bot here',
        '[from CT-AAAA-0001] @Pepa what did they say?',
      ]);
      expect(call.system, contains(TopicTexts.context));
      // One answer only (the owner's).
      expect(hub.calls('SendReliableGroupFanout'), hasLength(1));
    },
  );

  test('T3 off: unaddressed messages leave no trace', () async {
    settings();
    hub.deliver(await text(member, 'hi all'));
    await until(() => acks() == 1);
    expect(await store.history(groupId), isEmpty);
  });

  test('T4: a human member is answered without a mention, a bot not', () async {
    settings(withoutMention: true);
    provider.scripts.add(() => answer(['hello']));
    hub.deliver(await text(member, 'anyone?'));
    hub.deliver(await text(peer, 'bots too?'));
    await until(() => acks() == 2);
    expect(
      provider.calls.single.conversation.last.text,
      '[from CT-BBBB-0002] anyone?',
    );
    expect(hub.calls('SendReliableGroupFanout'), hasLength(1));
  });
}
