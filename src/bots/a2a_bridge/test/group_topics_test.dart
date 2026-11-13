import 'dart:convert';
import 'dart:io';

import 'package:a2a_bridge/a2a_bridge.dart';
import 'package:a2a_bridge/src/jay_glue.dart';
import 'package:calltype_bot/calltype_bot.dart';
import 'package:test/test.dart';

import '../../calltype_bot/test/helpers.dart';
import 'support/fake_a2a_server.dart';

/// Group topics in the A2A bridge (spec 2026-11-13-group-topics T2/T3): the
/// topic as a leading text part (first turn of a run / changed) plus
/// metadata `jayGroupTopic`, and group context as a leading part.
void main() {
  late Directory dir;
  late FakeA2aServer server;
  late A2aClient client;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('a2a_topics_test');
    server = await FakeA2aServer.start();
    server.cards['/.well-known/agent-card.json'] = v1Card('${server.url}/');
    server.onRpc = (_) =>
        ok({'task': v1Task('t', 'TASK_STATE_COMPLETED', text: 'ok')});
    client = A2aClient(agentUrl: server.url);
  });

  tearDown(() async {
    client.close();
    await server.close();
    await dir.delete(recursive: true);
  });

  Future<A2aBridge> bridge() async => A2aBridge(
    client: client,
    state: await StateStore.open('${dir.path}/state.json'),
    card: await client.discover(),
    timeout: const Duration(seconds: 5),
    pollInterval: const Duration(milliseconds: 20),
  );

  List<String> texts(RpcCall call) => [
    for (final p in call.message['parts'] as List) (p as Map)['text'] as String,
  ];

  group('bridge', () {
    test(
      'topic part on the first turn and on change; metadata on every turn',
      () async {
        var b = await bridge();
        Future<void> turn(String text, String? topic, int? version) => b.handle(
          conversationId: 'G1',
          text: text,
          sink: _Sink(),
          senderLabel: 'CT-AAAA-0001',
          groupTopic: topic,
          groupTopicVersion: version,
        );
        await turn('one', 'Brno', 5);
        await turn('two', 'Brno', 5);
        await turn('three', 'Prague', 6);
        expect(texts(server.calls[0]), [
          '[Group topic (set by the group admins): Brno]',
          '[from CT-AAAA-0001] one',
        ]);
        expect(server.calls[0].message['metadata'], {'jayGroupTopic': 'Brno'});
        expect(texts(server.calls[1]), ['[from CT-AAAA-0001] two']);
        expect(server.calls[1].message['metadata'], {'jayGroupTopic': 'Brno'});
        expect(texts(server.calls[2]).first, contains('Prague'));

        // A restart: told once more on the first turn of the new run.
        b = await bridge();
        await turn('four', 'Prague', 6);
        await turn('five', 'Prague', 6);
        expect(texts(server.calls[3]).first, contains('Prague'));
        expect(texts(server.calls[4]), hasLength(1));

        // Cleared: said once; no topic = no metadata.
        await turn('six', null, 7);
        expect(texts(server.calls[5]).first, contains('cleared'));
        expect(server.calls[5].message.containsKey('metadata'), isFalse);
        // The version survives in the state file, next to the task state.
        final json =
            jsonDecode(await File('${dir.path}/state.json').readAsString())
                as Map;
        expect(json['topics'], {'g1': 7});
      },
    );

    test('/reset: the new agent context hears the topic again', () async {
      final b = await bridge();
      Future<void> turn(String text) => b.handle(
        conversationId: 'G1',
        text: text,
        sink: _Sink(),
        groupTopic: 'Brno',
        groupTopicVersion: 5,
      );
      await turn('one');
      await turn('/reset');
      await turn('two');
      expect(server.calls, hasLength(2));
      expect(texts(server.calls[1]).first, contains('Brno'));
    });

    test('group context is a leading part; 1:1 has neither', () async {
      final b = await bridge();
      await b.handle(
        conversationId: 'G1',
        text: 'who brings what?',
        sink: _Sink(),
        groupContext: '[Meanwhile in the group:\n- Bob: tent]',
      );
      await b.handle(conversationId: 'U1', text: 'hi', sink: _Sink());
      expect(texts(server.calls[0]), [
        '[Meanwhile in the group:\n- Bob: tent]',
        'who brings what?',
      ]);
      expect(texts(server.calls[1]), ['hi']);
      expect(server.calls[1].message.containsKey('metadata'), isFalse);
    });
  });

  group('on the runtime', () {
    const groupId = '00000000-0000-4000-8000-0000000000c0';
    late FakeApi api;
    late FakeHub hub;
    late FakeUser owner;
    late FakeUser bob;
    late CallTypeBot bot;

    setUp(() async {
      api = await FakeApi.start();
      hub = FakeHub();
      owner = await FakeUser.create('00000000-0000-4000-8000-00000000000a');
      bob = await FakeUser.create('00000000-0000-4000-8000-00000000000b');
      api.keyBundles[owner.id] = await owner.keyBundle();
      api.keyBundles[bob.id] = await bob.keyBundle();
      bot = await CallTypeBot.start(
        apiBaseUrl: api.url,
        storePath: '${dir.path}/bot.store',
        storeKeyBase64: testStoreKey,
        transportFactory: (_, _) => hub,
        log: (_) {},
        sendRetryDelay: Duration.zero,
      );
      api.groups[groupId] = [owner.id, bob.id, bot.deviceId];
      api.memberFields[bob.id] = {'userHandle': 'CT-BBBB-0002'};
      api.groupDetails[groupId] = {
        'groupId': groupId,
        'botTalk': {'mode': 'off', 'botsReadAll': true},
        'topic': {'version': 3, 'updatedBy': bob.id},
      };
      await runJayGlue(
        bot,
        bridge: await bridge(),
        allowedIds: {owner.id.toLowerCase(): 'CT-AAAA-0001'},
        ackReactions: false,
        log: (_) {},
      );
    });

    tearDown(() async {
      await bot.close();
      await owner.close();
      await bob.close();
      await api.close();
    });

    test(
      "a non-owner's topic and chatter reach the agent's next turn",
      () async {
        Future<void> deliver(Map<String, dynamic> m) async {
          final before = hub.calls('AcknowledgeMessage').length;
          hub.deliver(m);
          await until(
            () => hub.calls('AcknowledgeMessage').length == before + 1,
          );
        }

        await deliver(
          await bob.messageTo(
            bot.deviceId,
            api.botBundle,
            jsonEncode({'topic': 'Brno trip', 'version': 3}),
            groupId: groupId,
            extra: const {'type': groupTopicType},
          ),
        );
        await deliver(
          await bob.messageTo(
            bot.deviceId,
            api.botBundle,
            'I bring the tent',
            groupId: groupId,
          ),
        );
        expect(server.calls, isEmpty); // context is never a turn
        await deliver(
          await owner.messageTo(
            bot.deviceId,
            api.botBundle,
            '@${bot.handle} plan?',
            groupId: groupId,
          ),
        );
        expect(texts(server.calls.single), [
          '[Group topic (set by the group admins): Brno trip]',
          '[Meanwhile in the group:\n- CT-BBBB-0002: I bring the tent]',
          '[from CT-AAAA-0001] @${bot.handle} plan?',
        ]);
        expect(server.calls.single.message['metadata'], {
          'jayGroupTopic': 'Brno trip',
        });
      },
    );
  });
}

class _Sink implements ChatSink {
  @override
  Future<ProgressHandle> progress(String text) async => _Progress();

  @override
  Future<void> reply(String text) async {}
}

class _Progress implements ProgressHandle {
  @override
  Future<void> update(String text) async {}
}
