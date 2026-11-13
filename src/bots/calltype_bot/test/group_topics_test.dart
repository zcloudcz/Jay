import 'dart:convert';
import 'dart:io';

import 'package:calltype_bot/calltype_bot.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Group topics in the runtime (spec 2026-11-13-group-topics T2-T4, receiver
/// rules in "Wire shapes"), over the real-crypto fakes.
void main() {
  const groupId = '00000000-0000-4000-8000-0000000000c0';
  late Directory dir;
  late FakeApi api;
  late FakeHub hub;
  late FakeUser alice; // human member, admin
  late FakeUser bob; // human member
  late FakeUser peer; // another bot
  late CallTypeBot bot;
  final logs = <String>[];

  Future<CallTypeBot> startBot() => CallTypeBot.start(
    apiBaseUrl: api.url,
    storePath: '${dir.path}/bot.store',
    storeKeyBase64: testStoreKey,
    displayName: 'Hermes',
    transportFactory: (_, _) => hub,
    log: logs.add,
    sendRetryDelay: Duration.zero,
  );

  setUp(() async {
    logs.clear();
    dir = await Directory.systemTemp.createTemp('calltype_bot_topic_test');
    api = await FakeApi.start();
    hub = FakeHub();
    alice = await FakeUser.create('00000000-0000-4000-8000-00000000000a');
    bob = await FakeUser.create('00000000-0000-4000-8000-00000000000b');
    peer = await FakeUser.create('00000000-0000-4000-8000-0000000000d1');
    for (final u in [alice, bob, peer]) {
      api.keyBundles[u.id] = await u.keyBundle();
    }
    bot = await startBot();
    api.groups[groupId] = [alice.id, bob.id, peer.id, bot.deviceId];
    api.memberFields[alice.id] = {
      'role': 'admin',
      'userHandle': 'CT-AAAA-0001',
      'displayName': 'Alice',
    };
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

  /// GET /groups/{id} with a topic record and the two reading flags.
  void serverState({
    int? version,
    String? by,
    bool readAll = false,
    bool withoutMention = false,
  }) {
    api.groupDetails[groupId] = {
      'groupId': groupId,
      'botTalk': {
        'mode': 'off',
        'botsReadAll': readAll,
        'replyWithoutMention': withoutMention,
      },
      'topic': version == null
          ? null
          : {
              'version': version,
              'updatedBy': by,
              'updatedAt': DateTime.now().toUtc().toIso8601String(),
            },
    };
  }

  Future<Map<String, dynamic>> topicFrom(
    FakeUser user,
    String topic,
    int version, {
    String? group = groupId,
    Object? body,
  }) => user.messageTo(
    bot.deviceId,
    api.botBundle,
    (body ?? jsonEncode({'topic': topic, 'version': version})) as String,
    groupId: group,
    extra: const {'type': groupTopicType},
  );

  Future<Map<String, dynamic>> textFrom(FakeUser user, String text) =>
      user.messageTo(bot.deviceId, api.botBundle, text, groupId: groupId);

  int acks() => hub.calls('AcknowledgeMessage').length;

  group('T2: topic receiver rules', () {
    test(
      'a recorded topic is stored, exposed on group messages and survives a restart',
      () async {
        serverState(version: 5, by: alice.id.toUpperCase());
        final seen = <BotMessage>[];
        await bot.onMessage((m) async => seen.add(m));
        // Cached before: the topic check must read the server again.
        await bot.group(groupId);
        hub.deliver(await topicFrom(alice, '  Plan the Brno trip.  ', 5));
        hub.deliver(await textFrom(alice, '@hermes hi'));
        await until(() => seen.length == 1 && acks() == 2);
        expect(seen.single.groupTopic, 'Plan the Brno trip.');
        expect(seen.single.groupTopicVersion, 5);
        expect(
          api.requests.where((r) => r == 'GET /groups/$groupId').length,
          greaterThanOrEqualTo(2),
        );
        final stored = await bot.groupTopic(groupId);
        expect(stored!.topic, 'Plan the Brno trip.');
        expect(stored.setBy, alice.id);
        // The content never reaches the log.
        expect(logs.any((l) => l.contains('Brno')), isFalse);

        await bot.close();
        bot = await startBot();
        expect((await bot.groupTopic(groupId))?.version, 5);
        expect((await bot.groupTopic(groupId))?.topic, 'Plan the Brno trip.');
      },
    );

    test('1:1 messages have no topic; a cleared topic reads as null', () async {
      serverState(version: 7, by: alice.id);
      final seen = <BotMessage>[];
      await bot.onMessage((m) async => seen.add(m));
      hub.deliver(await topicFrom(alice, '', 7));
      hub.deliver(await textFrom(alice, '@hermes hi'));
      hub.deliver(await alice.messageTo(bot.deviceId, api.botBundle, 'direct'));
      await until(() => seen.length == 2);
      // Separate conversation queues: the 1:1 message may come first.
      final inGroup = seen.singleWhere((m) => m.isGroup);
      final direct = seen.singleWhere((m) => !m.isGroup);
      expect(inGroup.groupTopic, isNull);
      expect(inGroup.groupTopicVersion, 7);
      expect(direct.groupTopic, isNull);
      expect(direct.groupTopicVersion, isNull);
    });

    test('refusals are acked and change nothing', () async {
      serverState(version: 9, by: alice.id);
      final seen = <BotMessage>[];
      await bot.onMessage((m) async => seen.add(m));
      // Stored first: version 9 from alice.
      hub.deliver(await topicFrom(alice, 'first', 9));
      await until(() => acks() == 1);
      expect((await bot.groupTopic(groupId))?.topic, 'first');

      // Wrong version (not the record), other sender, 1:1, malformed body.
      hub.deliver(await topicFrom(alice, 'stale', 8));
      hub.deliver(await topicFrom(bob, 'forged', 9));
      hub.deliver(await topicFrom(alice, 'direct', 9, group: null));
      hub.deliver(await topicFrom(alice, '', 9, body: '{"topic":1}'));
      // Equal version again: a no-op.
      hub.deliver(await topicFrom(alice, 'again', 9));
      await until(() => acks() == 6);
      expect((await bot.groupTopic(groupId))?.topic, 'first');

      // An older version the server still names (it cannot go back).
      serverState(version: 3, by: alice.id);
      hub.deliver(await topicFrom(alice, 'older', 3));
      await until(() => acks() == 7);
      expect((await bot.groupTopic(groupId))?.topic, 'first');
      expect(seen, isEmpty);
      expect(hub.calls('TypingIndicator'), isEmpty);
    });

    test('server unreadable: logged, acked, dropped (at most once)', () async {
      await bot.onMessage((_) async {});
      api.groups.remove(groupId); // GET answers 404
      hub.deliver(await topicFrom(alice, 'lost', 4));
      await until(() => acks() == 1);
      expect(await bot.groupTopic(groupId), isNull);
      expect(logs.any((l) => l.contains('not verified')), isTrue);
    });

    test(
      "a refused sender's topic applies when the bridge serves the group",
      () async {
        serverState(version: 11, by: bob.id);
        final seen = <BotMessage>[];
        await bot.onMessage(
          (m) async => seen.add(m),
          allowSender: (id) => id == alice.id,
          servesGroup: (_) async => true,
        );
        hub.deliver(await topicFrom(bob, 'from a non-owner admin', 11));
        // Not context (botsReadAll off) and never a turn.
        hub.deliver(await textFrom(bob, '@hermes do it'));
        await until(() => acks() == 2);
        expect(
          (await bot.groupTopic(groupId))?.topic,
          'from a non-owner admin',
        );
        expect(seen, isEmpty);
      },
    );

    test('without servesGroup a refused sender stays dropped blind', () async {
      serverState(version: 11, by: bob.id);
      await bot.onMessage((_) async {}, allowSender: (id) => id == alice.id);
      hub.deliver(await topicFrom(bob, 'ignored', 11));
      await until(() => acks() == 1);
      expect(await bot.groupTopic(groupId), isNull);
      // Acked before any lookup: nothing was decrypted or verified.
      expect(api.requests.where((r) => r.startsWith('GET /groups')), isEmpty);
    });
  });

  group('T4: reply without mention', () {
    test('a human member is addressed, a bot is not', () async {
      serverState(withoutMention: true);
      final seen = <BotMessage>[];
      await bot.onMessage((m) async => seen.add(m));
      hub.deliver(await textFrom(bob, 'what time is it'));
      hub.deliver(await textFrom(peer, 'I am a bot'));
      await until(() => acks() == 2);
      expect(seen.map((m) => m.text), ['what time is it']);
      expect(seen.single.addressed, isTrue);
      expect(seen.single.addressedByGroupSetting, isTrue);
      expect(seen.single.mentionsBot, isFalse);
      expect(seen.single.senderIsBot, isFalse);
    });

    test('off (default): unaddressed messages stay ignored', () async {
      serverState();
      final seen = <BotMessage>[];
      await bot.onMessage((m) async => seen.add(m));
      hub.deliver(await textFrom(bob, 'chatting'));
      hub.deliver(await textFrom(bob, '@hermes now you'));
      await until(() => acks() == 2);
      expect(seen.map((m) => m.text), ['@hermes now you']);
      expect(seen.single.addressedByGroupSetting, isFalse);
    });
  });

  group('T3: context', () {
    test(
      'unaddressed and refused group messages reach onContext only',
      () async {
        serverState(readAll: true, version: 2, by: alice.id);
        final turns = <BotMessage>[];
        final context = <BotMessage>[];
        bot.onContext((m) async => context.add(m));
        await bot.onMessage(
          (m) async => turns.add(m),
          // Bob and the peer bot are refused for turns.
          allowSender: (id) => id == alice.id,
          servesGroup: (_) async => true,
          ackReactions: const AckReactions(),
        );
        hub.deliver(await topicFrom(alice, 'Brno', 2));
        hub.deliver(await textFrom(alice, 'just chatting'));
        hub.deliver(await textFrom(bob, '@hermes refused but read'));
        hub.deliver(await textFrom(peer, 'bot chatter'));
        hub.deliver(await textFrom(alice, '@hermes answer this'));
        await until(() => acks() == 5);
        expect(context.map((m) => m.text), [
          'just chatting',
          '@hermes refused but read',
          'bot chatter',
        ]);
        expect(context.every((m) => m.isContext), isTrue);
        expect(context.first.senderDisplayName, 'Alice');
        expect(context.first.groupTopic, 'Brno');
        expect(context[2].senderIsBot, isTrue);
        expect(context[2].senderHandle, 'CT-PEER-0001');
        expect(turns.map((m) => m.text), ['@hermes answer this']);
        // One turn: one typing burst and the 👀 + ✅/👍 pair of that turn
        // only; context gets neither.
        expect(
          hub.calls('TypingIndicator').every((c) => c.single == groupId),
          isTrue,
        );
        final reactions = hub.calls('SendReliableGroupFanout');
        expect(reactions, hasLength(2));
      },
    );

    test('botsReadAll off: nothing reaches onContext', () async {
      serverState();
      final context = <BotMessage>[];
      bot.onContext((m) async => context.add(m));
      await bot.onMessage(
        (_) async {},
        allowSender: (id) => id == alice.id,
        servesGroup: (_) async => true,
      );
      hub.deliver(await textFrom(alice, 'chatting'));
      hub.deliver(await textFrom(bob, 'refused'));
      await until(() => acks() == 2);
      expect(context, isEmpty);
    });

    test('a group the bridge does not serve: nothing, refused blind', () async {
      serverState(readAll: true);
      final context = <BotMessage>[];
      final asked = <String>[];
      bot.onContext((m) async => context.add(m));
      await bot.onMessage(
        (_) async {},
        allowSender: (id) => id == alice.id,
        servesGroup: (g) async {
          asked.add(g);
          return false;
        },
      );
      hub.deliver(await textFrom(alice, 'chatting'));
      hub.deliver(await textFrom(bob, 'refused'));
      await until(() => acks() == 2);
      expect(context, isEmpty);
      expect(asked, [groupId, groupId]);
    });

    test(
      "a refused sender's reaction never reaches the reaction handler",
      () async {
        serverState(readAll: true);
        final reactions = <BotReaction>[];
        final context = <BotMessage>[];
        bot.onReaction((r) async => reactions.add(r));
        bot.onContext((m) async => context.add(m));
        await bot.onMessage(
          (_) async {},
          allowSender: (id) => id == alice.id,
          servesGroup: (_) async => true,
        );
        hub.deliver(
          await bob.messageTo(
            bot.deviceId,
            api.botBundle,
            ReactionPayload(targetId: 'x', emoji: '👍').encode(),
            groupId: groupId,
            extra: const {'type': reactionType},
          ),
        );
        await until(() => acks() == 1);
        expect(reactions, isEmpty);
        expect(context, isEmpty);
      },
    );

    test('a failing context handler is logged and still acked', () async {
      serverState(readAll: true);
      bot.onContext((_) async => throw StateError('boom'));
      await bot.onMessage((_) async {}, servesGroup: (_) async => true);
      hub.deliver(await textFrom(bob, 'chatting'));
      await until(() => acks() == 1);
      expect(logs.any((l) => l.contains('Context handler failed')), isTrue);
      expect(hub.calls('SendReliableGroupFanout'), isEmpty);
    });
  });
}
