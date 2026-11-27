import 'dart:convert';
import 'dart:io';

import 'package:calltype_bot/calltype_bot.dart';
import 'package:llm_bridge/llm_bridge.dart';
import 'package:llm_bridge/src/jay_glue.dart';
import 'package:test/test.dart';

import '../../calltype_bot/test/helpers.dart';
import 'support/fakes.dart';

/// Public 1:1 mode (spec 2026-11-27-bot-public-dm) on the REAL bot runtime:
/// real crypto, fake hub + loopback REST.
void main() {
  late Directory dir;
  late FakeApi api;
  late FakeHub hub;
  late FakeUser owner;
  late FakeUser stranger;
  late FakeUser peerBot;
  late CallTypeBot bot;
  late FakeProvider provider;
  late FakeGenerator generator;
  late _RecordingRunner runner;
  late List<String> logs;

  setUp(() async {
    logs = <String>[];
    dir = await Directory.systemTemp.createTemp('llm_public_test');
    api = await FakeApi.start();
    owner = await FakeUser.create('00000000-0000-4000-8000-00000000000a');
    stranger = await FakeUser.create('00000000-0000-4000-8000-00000000000e');
    // Not ...0b0: that is FakeApi.botId, the bot itself.
    peerBot = await FakeUser.create('00000000-0000-4000-8000-0000000000d0');
    for (final u in [owner, stranger, peerBot]) {
      api.keyBundles[u.id] = await u.keyBundle();
    }
    api.handles['CT-AAAA-0001'] = owner.id;
    api.profiles[stranger.id] = {
      'deviceId': stranger.id,
      'userHandle': 'CT-STRA-0001',
      'isBot': false,
    };
    api.profiles[peerBot.id] = {
      'deviceId': peerBot.id,
      'userHandle': 'CT-PEER-B0T1',
      'isBot': true,
    };
    hub = FakeHub();
    bot = await CallTypeBot.start(
      apiBaseUrl: api.url,
      storePath: '${dir.path}/bot.store',
      storeKeyBase64: testStoreKey,
      displayName: 'Demo',
      transportFactory: (_, _) => hub,
      log: logs.add,
      sendRetryDelay: Duration.zero,
    );
    provider = FakeProvider();
    generator = FakeGenerator();
    runner = _RecordingRunner();
    final store = await HistoryStore.open(
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
        displayName: 'Demo',
        systemPrompt: 's',
        progressAfter: Duration.zero,
        imageGenerator: generator,
        mediaDir: '${dir.path}/bot.store.media',
        actions: runner,
      ),
      allowedIds: allowed,
      // What LlmConfig makes of PUBLIC_DM=on (P2).
      inbound: 'open',
      publicDm: PublicDmLimiter(rate: 2, daily: 100, botRate: 1),
      ackReactions: false,
      log: logs.add,
    );
  });

  tearDown(() async {
    await bot.close();
    for (final u in [owner, stranger, peerBot]) {
      await u.close();
    }
    await api.close();
    await dir.delete(recursive: true);
  });

  Future<void> send(FakeUser from, String text, {String? groupId}) async {
    final before = hub.calls('AcknowledgeMessage').length;
    hub.deliver(
      await from.messageTo(bot.deviceId, api.botBundle, text, groupId: groupId),
    );
    await until(() => hub.calls('AcknowledgeMessage').length == before + 1);
  }

  Future<String> lastReplyTo(FakeUser user) async => user.read(
    bot.deviceId,
    (hub.calls('SendReliableDirectFanout').last[3]
        as Map<String, String>)[user.id]!,
  );

  int replies() => hub.calls('SendReliableDirectFanout').length;

  test('P2: publishes the open inbound policy', () {
    expect(api.botPolicies[FakeApi.botId]?['mode'], 'open');
    expect(logs, contains(startsWith('Public 1:1: on (per stranger 2/h')));
  });

  test('a stranger is answered in its own conversation, logged without '
      'content', () async {
    provider.scripts
      ..add(() => answer(['Ahoj, jsem demo.']))
      ..add(() => answer(['Hi owner']));
    await send(stranger, 'tajna otazka');
    await until(() => replies() == 1);
    expect(await lastReplyTo(stranger), 'Ahoj, jsem demo.');
    await send(owner, 'hello');
    await until(() => replies() == 2);
    // P9: the owner's call does not see the stranger's turn.
    expect(provider.calls[1].conversation.map((t) => t.text), ['hello']);
    final lines = logs.where((l) => l.startsWith('Public 1:1: CT-'));
    expect(lines, ['Public 1:1: CT-STRA-0001 (human): answered']);
    expect(logs.where((l) => l.contains('tajna')), isEmpty);
  });

  test(
    'P5: a stranger never runs actions and never generates images',
    () async {
      provider.scripts.add(
        () => answer(['[action: status] Hotovo. [[image: a red square]]']),
      );
      await send(stranger, 'restart it and draw');
      await until(() => replies() == 1);
      expect(runner.ran, isEmpty);
      expect(generator.prompts, isEmpty);
      final system = provider.calls.single.system;
      expect(system, isNot(contains('Actions:')));
      expect(system, isNot(contains(ImageTexts.generationHint)));
      expect(await lastReplyTo(stranger), contains('[[image: a red square]]'));
    },
  );

  test('the owner keeps actions and image generation', () async {
    provider.scripts
      ..add(() => answer(['[action: status]']))
      ..add(() => answer(['Běží.']));
    await send(owner, 'stav?');
    await until(() => replies() == 1);
    expect(runner.ran, ['status']);
    expect(provider.calls.first.system, contains(ImageTexts.generationHint));
  });

  test('P6: over the hourly limit one notice, then silence', () async {
    provider.scripts
      ..add(() => answer(['1']))
      ..add(() => answer(['2']));
    await send(stranger, 'a');
    await send(stranger, 'b');
    await until(() => replies() == 2);
    await send(stranger, 'c');
    await until(() => replies() == 3);
    expect(await lastReplyTo(stranger), BridgeTexts.publicSenderLimit);
    await send(stranger, 'd');
    expect(replies(), 3);
    expect(provider.calls, hasLength(2));
    expect(
      logs.where((l) => l.startsWith('Public 1:1: CT-STRA-0001')).toList(),
      [
        'Public 1:1: CT-STRA-0001 (human): answered',
        'Public 1:1: CT-STRA-0001 (human): answered',
        'Public 1:1: CT-STRA-0001 (human): limit notice (hourly limit)',
        'Public 1:1: CT-STRA-0001 (human): dropped: public limit reached',
      ],
    );
  });

  test('the owner is never limited', () async {
    for (var i = 0; i < 4; i++) {
      provider.scripts.add(() => answer(['ok $i']));
    }
    for (var i = 0; i < 4; i++) {
      await send(owner, 'm$i');
    }
    await until(() => replies() == 4);
    expect(provider.calls, hasLength(4));
  });

  test('P8: a peer bot in 1:1 gets its own small limit and never a '
      'notice', () async {
    provider.scripts.add(() => answer(['hello bot']));
    await send(peerBot, 'ping');
    await until(() => replies() == 1);
    await send(peerBot, 'ping again');
    await send(peerBot, 'and again');
    expect(replies(), 1);
    expect(provider.calls, hasLength(1));
    expect(logs, contains('Public 1:1: CT-PEER-B0T1 (bot): answered'));
    expect(
      logs,
      contains('Public 1:1: CT-PEER-B0T1 (bot): dropped: public limit reached'),
    );
  });

  test('an unknown profile counts as a bot (fail closed)', () async {
    api.profiles.remove(stranger.id);
    provider.scripts.add(() => answer(['x']));
    await send(stranger, 'a');
    await send(stranger, 'b');
    await until(() => replies() == 1);
    expect(replies(), 1);
    expect(
      logs.where((l) => l.startsWith('Public 1:1: ${stranger.id}')),
      hasLength(2),
    );
    expect(logs, contains(contains('(unknown, treated as a bot)')));
  });

  test('P3: groups keep the owner rule (no owner = dropped before '
      'decrypt)', () async {
    const groupId = '00000000-0000-4000-8000-0000000000c2';
    api.groups[groupId] = [stranger.id, bot.deviceId];
    await send(stranger, '@${bot.handle} hi', groupId: groupId);
    expect(provider.calls, isEmpty);
    expect(hub.calls('SendReliableGroupFanout'), isEmpty);
    expect(logs.where((l) => l.startsWith('Public 1:1: CT-')), isEmpty);
  });
}

/// Records action names; runs nothing.
class _RecordingRunner extends ActionRunner {
  _RecordingRunner() : super(parseActions('status=fake-status'));

  final ran = <String>[];

  @override
  Future<ActionResult> run(String name) async {
    ran.add(name);
    return ActionResult(name: name, exitCode: 0, output: 'active');
  }
}
