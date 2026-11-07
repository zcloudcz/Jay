import 'dart:io';

import 'package:calltype_bot/calltype_bot.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// A bot SENDING reactions (spec 2026-11-07-message-reactions, section
/// "Bots"): the app's wire format, 1:1 and groups. Real crypto on both ends.
void main() {
  const groupId = '00000000-0000-4000-8000-0000000000c0';
  const targetId = '00000000-0000-4000-8000-0000000000f1';
  late Directory dir;
  late FakeApi api;
  late FakeHub hub;
  late FakeUser alice;
  late FakeUser bob;
  late CallTypeBot bot;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('calltype_bot_react_test');
    api = await FakeApi.start();
    hub = FakeHub();
    alice = await FakeUser.create('00000000-0000-4000-8000-00000000000a');
    bob = await FakeUser.create('00000000-0000-4000-8000-00000000000b');
    api.keyBundles[alice.id] = await alice.keyBundle();
    api.keyBundles[bob.id] = await bob.keyBundle();
    api.handles['CT-AAAA-0001'] = alice.id;
    bot = await CallTypeBot.start(
      apiBaseUrl: api.url,
      storePath: '${dir.path}/bot.store',
      storeKeyBase64: testStoreKey,
      displayName: 'Hermes',
      transportFactory: (_, _) => hub,
      log: (_) {},
      sendRetryDelay: Duration.zero,
    );
  });

  tearDown(() async {
    await bot.close();
    await alice.close();
    await bob.close();
    await api.close();
    await dir.delete(recursive: true);
  });

  /// What [user] decrypts from the bot's last call of [method].
  Future<Map<String, dynamic>> lastPayload(FakeUser user, String method) =>
      user.readPayload(
        bot.deviceId,
        (hub.calls(method).last[3] as Map<String, String>)[user.id]!,
      );

  test('1:1 by handle: a reaction payload the user can decrypt', () async {
    await bot.onMessage((_) async {});
    await bot.sendReaction(
      to: 'ct-aaaa-0001',
      targetMessageId: targetId,
      emoji: '👍🏽',
    );
    final sent = hub.calls('SendReliableDirectFanout').single;
    expect(sent[0], alice.id);
    final payload = await lastPayload(alice, 'SendReliableDirectFanout');
    expect(payload['type'], reactionType);
    expect(payload['to'], alice.id);
    expect(payload['groupId'], isNull);
    expect(payload['id'], sent[1]);
    expect(payload['createdAt'], isA<String>());
    expect(
      ReactionPayload.decode(payload['body']),
      const ReactionPayload(targetId: targetId, emoji: '👍🏽'),
    );
  });

  test('removal sends an empty emoji', () async {
    await bot.onMessage((_) async {});
    await bot.removeReaction(to: 'CT-AAAA-0001', targetMessageId: targetId);
    final payload = await lastPayload(alice, 'SendReliableDirectFanout');
    final reaction = ReactionPayload.decode(payload['body'])!;
    expect(reaction.removes, isTrue);
    expect(reaction.targetId, targetId);
  });

  test('group: fan-out to every other member with groupId set', () async {
    api.groups[groupId] = [alice.id, bob.id, bot.deviceId];
    await bot.onMessage((_) async {});
    await bot.sendReaction(to: groupId, targetMessageId: targetId, emoji: '❤️');
    final sent = hub.calls('SendReliableGroupFanout').single;
    expect(sent[0], groupId);
    expect((sent[3] as Map<String, String>).keys.toSet(), {alice.id, bob.id});
    final payload = await lastPayload(bob, 'SendReliableGroupFanout');
    expect(payload['type'], reactionType);
    expect(payload['groupId'], groupId);
    expect(payload.containsKey('to'), isFalse);
    expect(ReactionPayload.decode(payload['body'])!.emoji, '❤️');
  });

  test('invalid emoji, empty or long target and foreign targets are '
      'refused before anything is sent', () async {
    await bot.onMessage((_) async {});
    for (final emoji in ['ok', '👍👍', 'a👍', ' ']) {
      await expectLater(
        bot.sendReaction(
          to: 'CT-AAAA-0001',
          targetMessageId: targetId,
          emoji: emoji,
        ),
        throwsArgumentError,
        reason: emoji,
      );
    }
    for (final target in ['', '  ', 'x' * 65]) {
      await expectLater(
        bot.sendReaction(
          to: 'CT-AAAA-0001',
          targetMessageId: target,
          emoji: '👍',
        ),
        throwsArgumentError,
      );
    }
    await expectLater(
      bot.sendReaction(
        to: 'CT-NOPE-0000',
        targetMessageId: targetId,
        emoji: '👍',
      ),
      throwsA(isA<BotSendException>()),
    );
    api.groups[groupId] = [alice.id, bob.id]; // bot not a member
    await expectLater(
      bot.sendReaction(to: groupId, targetMessageId: targetId, emoji: '👍'),
      throwsA(isA<BotSendException>()),
    );
    expect(hub.calls('SendReliableDirectFanout'), isEmpty);
    expect(hub.calls('SendReliableGroupFanout'), isEmpty);
  });

  test('BotMessage.react reacts in the 1:1 conversation of the message, '
      'removeReaction clears it', () async {
    final done = <String>[];
    await bot.onMessage((m) async {
      await m.react('🎉');
      await m.removeReaction();
      done.add(m.id);
    });
    final incoming = await alice.messageTo(bot.deviceId, api.botBundle, 'hi');
    hub.deliver(incoming);
    await until(() => done.isNotEmpty);
    final sent = hub.calls('SendReliableDirectFanout');
    expect(sent, hasLength(2));
    expect(sent.first[0], alice.id);
    final first = await alice.readPayload(
      bot.deviceId,
      (sent.first[3] as Map<String, String>)[alice.id]!,
    );
    expect(
      ReactionPayload.decode(first['body']),
      ReactionPayload(targetId: done.single, emoji: '🎉'),
    );
    final second = await lastPayload(alice, 'SendReliableDirectFanout');
    expect(ReactionPayload.decode(second['body'])!.removes, isTrue);
    // No handle lookup: the message already names its conversation.
    expect(api.requests.where((r) => r.contains('handle')), isEmpty);
  });

  test('BotMessage.react in a group goes to the group', () async {
    api.groups[groupId] = [alice.id, bob.id, bot.deviceId];
    final done = <String>[];
    await bot.onMessage((m) async {
      await m.react('👀');
      done.add(m.id);
    });
    hub.deliver(
      await bob.messageTo(
        bot.deviceId,
        api.botBundle,
        '@Hermes look',
        groupId: groupId,
      ),
    );
    await until(() => done.isNotEmpty);
    final sent = hub.calls('SendReliableGroupFanout').single;
    expect(sent[0], groupId);
    final payload = await lastPayload(alice, 'SendReliableGroupFanout');
    expect(payload['groupId'], groupId);
    expect(
      ReactionPayload.decode(payload['body']),
      ReactionPayload(targetId: done.single, emoji: '👀'),
    );
  });

  test('BotMessage.react refuses an invalid emoji', () async {
    Object? error;
    final done = <bool>[];
    await bot.onMessage((m) async {
      try {
        await m.react('nope');
      } catch (e) {
        error = e;
      }
      done.add(true);
    });
    hub.deliver(await alice.messageTo(bot.deviceId, api.botBundle, 'hi'));
    await until(() => done.isNotEmpty);
    expect(error, isA<ArgumentError>());
    expect(hub.calls('SendReliableDirectFanout'), isEmpty);
  });
}
