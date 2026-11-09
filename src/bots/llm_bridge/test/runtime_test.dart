import 'dart:convert';
import 'dart:io';

import 'package:calltype_bot/calltype_bot.dart';
import 'package:llm_bridge/llm_bridge.dart';
import 'package:llm_bridge/src/jay_glue.dart';
import 'package:test/test.dart';

import '../../calltype_bot/test/helpers.dart';
import 'support/fakes.dart';

/// The bridge on the REAL bot runtime: real calltype_core crypto on both
/// sides, fake hub + loopback REST (calltype_bot's test helpers).
void main() {
  late Directory dir;
  late FakeApi api;
  late FakeHub hub;
  late FakeUser owner;
  late FakeUser stranger;
  late CallTypeBot bot;
  late FakeProvider provider;
  late HistoryStore store;
  final logs = <String>[];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('llm_runtime_test');
    api = await FakeApi.start();
    owner = await FakeUser.create('00000000-0000-4000-8000-00000000000a');
    stranger = await FakeUser.create('00000000-0000-4000-8000-00000000000e');
    api.keyBundles[owner.id] = await owner.keyBundle();
    api.keyBundles[stranger.id] = await stranger.keyBundle();
    api.handles['CT-AAAA-0001'] = owner.id;
    hub = FakeHub();
    bot = await CallTypeBot.start(
      apiBaseUrl: api.url,
      storePath: '${dir.path}/bot.store',
      storeKeyBase64: testStoreKey,
      displayName: 'Pepa',
      transportFactory: (_, _) => hub,
      log: logs.add,
      sendRetryDelay: Duration.zero,
    );
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
      log: logs.add,
    );
  });

  tearDown(() async {
    await bot.close();
    await owner.close();
    await stranger.close();
    await api.close();
    await dir.delete(recursive: true);
  });

  test('publishes /new and /help as the bot menu', () {
    final published = api.botCommands[FakeApi.botId] as Map;
    expect(
      [for (final c in published['commands'] as List) c['command']],
      ['new', 'help'],
    );
  });

  test('owner message -> provider -> encrypted reply', () async {
    provider.scripts.add(() => answer(['Ahoj ', 'Martine']));
    hub.deliver(await owner.messageTo(bot.deviceId, api.botBundle, 'Ahoj'));
    await until(() => hub.calls('AcknowledgeMessage').isNotEmpty);
    final sent = hub.calls('SendReliableDirectFanout').single;
    expect(
      await owner.read(
        bot.deviceId,
        (sent[3] as Map<String, String>)[owner.id]!,
      ),
      'Ahoj Martine',
    );
    expect(provider.calls.single.conversation.single.text, 'Ahoj');
  });

  test(
    'non-owner is dropped before decrypt: no provider call, no reply',
    () async {
      hub.deliver(await stranger.messageTo(bot.deviceId, api.botBundle, 'hi'));
      await until(() => hub.calls('AcknowledgeMessage').isNotEmpty);
      expect(provider.calls, isEmpty);
      expect(hub.calls('TypingIndicator'), isEmpty);
      expect(hub.calls('SendReliableDirectFanout'), isEmpty);
    },
  );

  test('publishes the inbound policy: owners = the resolved handles', () {
    expect(api.botPolicies[FakeApi.botId], {
      'mode': 'owners',
      'owners': ['CT-AAAA-0001'],
    });
  });

  group('groups (bot-access A4)', () {
    const withOwner = '00000000-0000-4000-8000-0000000000c1';
    const withoutOwner = '00000000-0000-4000-8000-0000000000c2';
    late FakeUser other;

    setUp(() async {
      other = await FakeUser.create('00000000-0000-4000-8000-00000000000f');
      api.keyBundles[other.id] = await other.keyBundle();
      api.groups[withOwner] = [owner.id, stranger.id, bot.deviceId];
      api.groups[withoutOwner] = [stranger.id, other.id, bot.deviceId];
      api.memberFields[stranger.id] = {'userHandle': 'CT-MEMB-0002'};
    });
    tearDown(() => other.close());

    Future<void> say(FakeUser from, String group, String text) async {
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

    test('a member of a group with the owner is answered, labelled', () async {
      provider.scripts.add(() => answer(['Ahoj']));
      await say(stranger, withOwner, 'kolik je hodin?');
      expect(
        provider.calls.single.conversation.single.text,
        '[from CT-MEMB-0002] @${bot.handle} kolik je hodin?',
      );
      final sent = hub.calls('SendReliableGroupFanout').single;
      final payload = await stranger.readPayload(
        bot.deviceId,
        (sent[3] as Map<String, String>)[stranger.id]!,
      );
      expect(payload['body'], 'Ahoj');
      // The reply quotes the asker, like an answer to an owner.
      expect((payload['replyTo'] as Map)['senderId'], stranger.id);
    });

    test('the same member in a group without an owner gets nothing', () async {
      await say(stranger, withoutOwner, 'hello?');
      expect(provider.calls, isEmpty);
      expect(hub.calls('SendReliableGroupFanout'), isEmpty);
      expect(hub.calls('TypingIndicator'), isEmpty);
    });
  });

  test('greeting goes to each owner exactly once, across restarts', () async {
    Future<void> greet(HistoryStore s) => greetOwners(
      handles: ['CT-AAAA-0001'],
      store: s,
      send: (handle, text) => bot.send(to: handle, text: text),
      displayName: 'Pepa',
    );
    await greet(store);
    // A restart reopens the store from disk.
    await greet(
      await HistoryStore.open(
        '${dir.path}/bot.store.llm',
        base64Decode(testStoreKey),
        cap: 20,
      ),
    );
    final sends = hub.calls('SendReliableDirectFanout');
    expect(sends, hasLength(1));
    expect(
      await owner.read(
        bot.deviceId,
        (sends.single[3] as Map<String, String>)[owner.id]!,
      ),
      'Ahoj, jsem Pepa. Napiš mi.\nHi, I am Pepa. Write to me.',
    );
  });

  test('a failed greeting is not marked and is retried later', () async {
    final logs = <String>[];
    await greetOwners(
      handles: ['CT-AAAA-0001'],
      store: store,
      send: (_, _) async => throw StateError('offline'),
      displayName: 'Pepa',
      log: logs.add,
    );
    expect(await store.greeted('CT-AAAA-0001'), isFalse);
    expect(logs.single, contains('will retry'));
  });
}
