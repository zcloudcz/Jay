import 'dart:async';
import 'dart:io';

import 'package:calltype_bot/calltype_bot.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Emoji reactions in the runtime (spec 2026-11-07-message-reactions,
/// section "Bots"). Real crypto on both ends.
void main() {
  const groupId = '00000000-0000-4000-8000-0000000000c0';
  late Directory dir;
  late FakeApi api;
  late FakeHub hub;
  late FakeUser alice;
  late FakeUser bob;
  late CallTypeBot bot;
  final logs = <String>[];

  Future<CallTypeBot> startBot() async {
    hub = FakeHub();
    return CallTypeBot.start(
      apiBaseUrl: api.url,
      storePath: '${dir.path}/bot.store',
      storeKeyBase64: testStoreKey,
      displayName: 'Hermes',
      transportFactory: (_, _) => hub,
      log: logs.add,
      sendRetryDelay: Duration.zero,
    );
  }

  setUp(() async {
    logs.clear();
    dir = await Directory.systemTemp.createTemp('calltype_bot_reaction_test');
    api = await FakeApi.start();
    alice = await FakeUser.create('00000000-0000-4000-8000-00000000000a');
    bob = await FakeUser.create('00000000-0000-4000-8000-00000000000b');
    api.keyBundles[alice.id] = await alice.keyBundle();
    api.keyBundles[bob.id] = await bob.keyBundle();
    api.handles['CT-AAAA-0001'] = alice.id;
    bot = await startBot();
    api.groups[groupId] = [alice.id, bob.id, bot.deviceId];
  });

  tearDown(() async {
    await bot.close();
    await alice.close();
    await bob.close();
    await api.close();
    await dir.delete(recursive: true);
  });

  Future<void> deliver(
    FakeUser from,
    String body, {
    String? group,
    Map<String, dynamic> extra = const {},
  }) async {
    final before = hub.calls('AcknowledgeMessage').length;
    hub.deliver(
      await from.messageTo(
        bot.deviceId,
        api.botBundle,
        body,
        groupId: group,
        extra: extra,
      ),
    );
    await until(() => hub.calls('AcknowledgeMessage').length == before + 1);
  }

  /// [user] decrypts the bot's last group message (sets up the session).
  Future<void> readGroup(FakeUser user) => user.readPayload(
    bot.deviceId,
    (hub.calls('SendReliableGroupFanout').last[3]
        as Map<String, String>)[user.id]!,
  );

  Future<void> react(
    FakeUser from,
    String targetId,
    String emoji, {
    String? group,
  }) => deliver(
    from,
    ReactionPayload(targetId: targetId, emoji: emoji).encode(),
    group: group,
    extra: {'type': reactionType},
  );

  test('1:1: a reaction to the bot\'s message carries its text', () async {
    final reactions = <BotReaction>[];
    final messages = <BotMessage>[];
    bot.onReaction((r) async => reactions.add(r));
    final long = 'a' * 150 + '😀' * 100;
    await bot.onMessage((m) async {
      messages.add(m);
      await m.reply(long);
    });
    await deliver(alice, 'hi');
    final sentId =
        (await alice.readPayload(
              bot.deviceId,
              (hub.calls('SendReliableDirectFanout').last[3]
                  as Map<String, String>)[alice.id]!,
            ))['id']
            as String;

    await react(alice, sentId, '👍');
    final r = reactions.single;
    expect(r.emoji, '👍');
    expect(r.removed, isFalse);
    expect(r.targetId, sentId);
    expect(r.senderId, alice.id);
    expect(r.conversationId, alice.id);
    expect(r.isGroup, isFalse);
    expect(r.targetIsOwn, isTrue);
    // 200 characters, an emoji never cut in half.
    expect(r.targetText!.runes.length, reactionTargetChars);
    expect(r.targetText, long.substring(0, 150) + '😀' * 50);
    // A reaction is no message and gets no reply.
    expect(messages, hasLength(1));
    expect(hub.calls('SendReliableDirectFanout'), hasLength(1));

    await react(alice, sentId, '');
    expect(reactions.last.removed, isTrue);
  });

  test(
    '1:1: a reaction to an unknown message still arrives, without text',
    () async {
      final reactions = <BotReaction>[];
      bot.onReaction((r) async => reactions.add(r));
      await bot.onMessage((_) async {});
      await react(alice, 'not-remembered', '❤️');
      expect(reactions.single.targetIsOwn, isFalse);
      expect(reactions.single.targetText, isNull);
    },
  );

  test('an edit updates the remembered text', () async {
    final reactions = <BotReaction>[];
    bot.onReaction((r) async => reactions.add(r));
    await bot.onMessage((_) async {});
    final sent = await bot.send(to: 'CT-AAAA-0001', text: 'working...');
    await sent.edit('done: 3 files');
    // Alice needs the bot's first message to have a session.
    await alice.readPayload(
      bot.deviceId,
      (hub.calls('SendReliableDirectFanout').first[3]
          as Map<String, String>)[alice.id]!,
    );
    await react(alice, sent.id, '🎉');
    expect(reactions.single.targetText, 'done: 3 files');
  });

  test('group: only reactions to the bot\'s own messages arrive', () async {
    final reactions = <BotReaction>[];
    bot.onReaction((r) async => reactions.add(r));
    await bot.onMessage((_) async {});
    final sent = await bot.send(to: groupId, text: 'deployed');
    await readGroup(bob);
    await react(bob, 'someone-elses', '👍', group: groupId);
    expect(reactions, isEmpty);
    await react(bob, sent.id, '👍', group: groupId);
    expect(reactions.single.isGroup, isTrue);
    expect(reactions.single.groupId, groupId);
    expect(reactions.single.conversationId, groupId);
    expect(reactions.single.targetText, 'deployed');
  });

  test('a bot message of ANOTHER conversation is not "own" here', () async {
    final reactions = <BotReaction>[];
    bot.onReaction((r) async => reactions.add(r));
    await bot.onMessage((_) async {});
    final inGroup = await bot.send(to: groupId, text: 'group secret');
    await readGroup(alice);
    await react(alice, inGroup.id, '👀');
    expect(reactions.single.targetIsOwn, isFalse);
    expect(reactions.single.targetText, isNull);
  });

  test('invalid reactions are acknowledged and dropped', () async {
    final reactions = <BotReaction>[];
    bot.onReaction((r) async => reactions.add(r));
    await bot.onMessage((_) async {});
    await deliver(
      alice,
      '{"targetId":"m","emoji":"not emoji"}',
      extra: {'type': reactionType},
    );
    await deliver(alice, 'garbage', extra: {'type': reactionType});
    expect(reactions, isEmpty);
  });

  test('without onReaction a reaction is acknowledged and ignored, and '
      'nothing is remembered', () async {
    final messages = <BotMessage>[];
    await bot.onMessage((m) async {
      messages.add(m);
      await m.reply('pong');
    });
    await deliver(alice, 'ping');
    await react(alice, 'x', '👍');
    expect(messages, hasLength(1));
    expect(hub.calls('SendReliableDirectFanout'), hasLength(1));
  });

  test('a failing handler is logged, acked and never answered', () async {
    bot.onReaction((_) async => throw StateError('boom'));
    await bot.onMessage((_) async {});
    await react(alice, 'm', '👍');
    expect(
      logs.where((l) => l.contains('Reaction handler failed')),
      hasLength(1),
    );
    expect(hub.calls('SendReliableDirectFanout'), isEmpty);
  });

  test('a reaction waits for the conversation\'s turn in progress', () async {
    final order = <String>[];
    final release = Completer<void>();
    bot.onReaction((r) async => order.add('reaction'));
    await bot.onMessage((m) async {
      order.add('turn start');
      await release.future;
      order.add('turn end');
    });
    hub.deliver(await alice.messageTo(bot.deviceId, api.botBundle, 'slow'));
    await until(() => order.isNotEmpty);
    final acked = hub.calls('AcknowledgeMessage').length;
    hub.deliver(
      await alice.messageTo(
        bot.deviceId,
        api.botBundle,
        const ReactionPayload(targetId: 'm', emoji: '👍').encode(),
        extra: {'type': reactionType},
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(order, ['turn start']);
    release.complete();
    await until(() => hub.calls('AcknowledgeMessage').length == acked + 2);
    expect(order, ['turn start', 'turn end', 'reaction']);
  });
}
