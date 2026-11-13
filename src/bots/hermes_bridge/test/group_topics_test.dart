import 'dart:convert';
import 'dart:io';

import 'package:calltype_bot/calltype_bot.dart';
import 'package:hermes_bridge/hermes_bridge.dart';
import 'package:test/test.dart';

import '../../calltype_bot/test/helpers.dart';

/// Group topics in the Hermes bridge (spec 2026-11-13-group-topics T2/T3):
/// the topic block on the first turn and on change only, group context in
/// front of the next turn.
void main() {
  const groupId = '00000000-0000-4000-8000-0000000000c0';
  late Directory dir;
  late FakeApi api;
  late FakeHub hub;
  late FakeUser alice; // owner, admin
  late FakeUser bob; // human member, not an owner
  late FakeUser peer; // another bot
  late CallTypeBot bot;
  final prompts = <String>[];

  Future<String> backend(String text, {required String conversationId}) async {
    prompts.add(text);
    return 'ok';
  }

  Future<CallTypeBot> startBot() => CallTypeBot.start(
    apiBaseUrl: api.url,
    storePath: '${dir.path}/bot.store',
    storeKeyBase64: testStoreKey,
    transportFactory: (_, _) => hub,
    log: (_) {},
    sendRetryDelay: Duration.zero,
  );

  Future<HermesBridge> startBridge() => runBridge(
    bot,
    ackReactions: false,
    allowedHandles: {'CT-AAAA-0001'},
    backend: backend,
    log: (_) {},
  );

  setUp(() async {
    prompts.clear();
    dir = await Directory.systemTemp.createTemp('hermes_topics_test');
    api = await FakeApi.start();
    hub = FakeHub();
    alice = await FakeUser.create('00000000-0000-4000-8000-00000000000a');
    bob = await FakeUser.create('00000000-0000-4000-8000-00000000000b');
    peer = await FakeUser.create('00000000-0000-4000-8000-0000000000d1');
    for (final u in [alice, bob, peer]) {
      api.keyBundles[u.id] = await u.keyBundle();
    }
    api.handles['CT-AAAA-0001'] = alice.id;
    bot = await startBot();
    api.groups[groupId] = [alice.id, bob.id, peer.id, bot.deviceId];
    api.memberFields[alice.id] = {
      'role': 'admin',
      'userHandle': 'CT-AAAA-0001',
    };
    api.memberFields[bob.id] = {'userHandle': 'CT-BBBB-0002', 'role': 'admin'};
    api.memberFields[peer.id] = {'isBot': true, 'userHandle': 'CT-PEER-0001'};
  });

  tearDown(() async {
    await bot.close();
    for (final u in [alice, bob, peer]) {
      await u.close();
    }
    await api.close();
    await dir.delete(recursive: true);
  });

  void server({int? version, String? by, bool readAll = false}) =>
      api.groupDetails[groupId] = {
        'groupId': groupId,
        'botTalk': {'mode': 'off', 'botsReadAll': readAll},
        'topic': version == null ? null : {'version': version, 'updatedBy': by},
      };

  int acks() => hub.calls('AcknowledgeMessage').length;

  Future<void> deliver(Map<String, dynamic> message) async {
    final before = acks();
    hub.deliver(message);
    await until(() => acks() == before + 1);
  }

  Future<void> topic(FakeUser from, String text, int version) async => deliver(
    await from.messageTo(
      bot.deviceId,
      api.botBundle,
      jsonEncode({'topic': text, 'version': version}),
      groupId: groupId,
      extra: const {'type': groupTopicType},
    ),
  );

  Future<void> say(FakeUser from, String text) async => deliver(
    await from.messageTo(bot.deviceId, api.botBundle, text, groupId: groupId),
  );

  test('T2: topic block on the first turn and on change only', () async {
    server(version: 5, by: bob.id); // a non-owner admin sets it
    await startBridge();
    await topic(bob, 'Plan the Brno trip.', 5);
    await say(alice, '@${bot.handle} one');
    await say(alice, '@${bot.handle} two');
    server(version: 6, by: bob.id);
    await topic(bob, 'Plan the Prague trip.', 6);
    await say(alice, '@${bot.handle} three');
    expect(prompts, hasLength(3));
    expect(
      prompts[0],
      startsWith(
        '[Group topic (set by the group admins): Plan the Brno trip.]\n',
      ),
    );
    expect(prompts[1], isNot(contains('Group topic')));
    expect(
      prompts[2],
      startsWith(
        '[Group topic (set by the group admins): Plan the Prague trip.]',
      ),
    );

    // A restart: the first turn of the new run tells it once more.
    await bot.close();
    hub = FakeHub();
    bot = await startBot();
    await startBridge();
    await say(alice, '@${bot.handle} four');
    await say(alice, '@${bot.handle} five');
    expect(prompts[3], contains('Plan the Prague trip.'));
    expect(prompts[4], isNot(contains('Group topic')));
  });

  test('T3: context in front of the next turn, then cleared', () async {
    server(readAll: true);
    await startBridge();
    await say(bob, 'I bring the tent'); // refused for turns: context
    await say(peer, '@${bot.handle} weather is fine'); // bot talk off
    await say(alice, 'no mention here'); // owner, unaddressed
    expect(prompts, isEmpty);
    await say(alice, '@${bot.handle} who brings what?');
    await say(alice, '@${bot.handle} thanks');
    expect(prompts, hasLength(2));
    expect(
      prompts[0],
      startsWith(
        '[Meanwhile in the group:\n'
        '- CT-BBBB-0002: I bring the tent\n'
        '- CT-PEER-0001 (bot): @${bot.handle} weather is fine\n'
        '- CT-AAAA-0001: no mention here]\n',
      ),
    );
    expect(prompts[1], isNot(contains('Meanwhile')));
    // Context is never answered: only the two turns replied.
    expect(hub.calls('SendReliableGroupFanout'), hasLength(2));
  });

  test('T3 off: other members stay unheard', () async {
    server();
    await startBridge();
    await say(bob, 'I bring the tent');
    await say(alice, '@${bot.handle} hi');
    expect(prompts.single, isNot(contains('Meanwhile')));
  });
}
