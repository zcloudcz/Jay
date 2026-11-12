import 'dart:io';

import 'package:calltype_bot/calltype_bot.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Acknowledgement reactions (spec 2026-11-11-bot-ack-reactions): 👀 on an
/// accepted message before the turn, then ✅ / 👍 / ❌ or the handler's own
/// emoji. Real crypto on both ends.
void main() {
  const groupId = '00000000-0000-4000-8000-0000000000c0';
  late Directory dir;
  late FakeApi api;
  late FakeHub hub;
  late FakeUser alice;
  late FakeUser bob;
  late CallTypeBot bot;
  late List<String> logs;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('calltype_bot_ack_test');
    api = await FakeApi.start();
    hub = FakeHub();
    logs = [];
    alice = await FakeUser.create('00000000-0000-4000-8000-00000000000a');
    bob = await FakeUser.create('00000000-0000-4000-8000-00000000000b');
    api.keyBundles[alice.id] = await alice.keyBundle();
    api.keyBundles[bob.id] = await bob.keyBundle();
    bot = await CallTypeBot.start(
      apiBaseUrl: api.url,
      storePath: '${dir.path}/bot.store',
      storeKeyBase64: testStoreKey,
      displayName: 'Hermes',
      transportFactory: (_, _) => hub,
      log: logs.add,
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

  /// Everything the bot sent to [user] through [method], decrypted in order
  /// (the ratchet needs every message, replies included).
  Future<List<Map<String, dynamic>>> sentTo(
    FakeUser user, {
    String method = 'SendReliableDirectFanout',
  }) async => [
    for (final call in hub.calls(method))
      await user.readPayload(
        bot.deviceId,
        (call[3] as Map<String, String>)[user.id]!,
      ),
  ];

  /// The payloads as short strings: `react:<target>:<emoji>` or the text.
  Future<List<String>> transcript(
    FakeUser user, {
    String method = 'SendReliableDirectFanout',
  }) async => [
    for (final p in await sentTo(user, method: method))
      if (p['type'] == reactionType)
        'react:${ReactionPayload.decode(p['body'])!.targetId}:'
            '${ReactionPayload.decode(p['body'])!.emoji}'
      else
        p['body'] as String,
  ];

  Future<String> deliver(
    FakeUser from,
    String text, {
    String? groupId,
    Map<String, dynamic> extra = const {},
    String? messageId,
  }) async {
    final m = await from.messageTo(
      bot.deviceId,
      api.botBundle,
      text,
      groupId: groupId,
      extra: extra,
      messageId: messageId,
    );
    hub.deliver(m);
    return m['messageId'] as String;
  }

  group('automatic receipt', () {
    test('👀 before the turn, ✅ after a reply', () async {
      final done = <String>[];
      var callsAtStart = -1;
      await bot.onMessage((m) async {
        callsAtStart = hub.calls('SendReliableDirectFanout').length;
        await m.reply('hi');
        done.add(m.id);
      }, ackReactions: const AckReactions());
      final id = await deliver(alice, 'ahoj');
      await until(() => done.isNotEmpty);
      await until(() => hub.calls('SendReliableDirectFanout').length == 3);
      expect(callsAtStart, 1, reason: 'receipt sent before the handler');
      expect(await transcript(alice), ['react:$id:👀', 'hi', 'react:$id:✅']);
    });

    test('no reply: 👍', () async {
      final done = <String>[];
      await bot.onMessage(
        (m) async => done.add(m.id),
        ackReactions: const AckReactions(),
      );
      final id = await deliver(alice, 'díky');
      await until(() => hub.calls('SendReliableDirectFanout').length == 2);
      expect(await transcript(alice), ['react:$id:👀', 'react:$id:👍']);
    });

    test('handler throws: apology and ❌', () async {
      await bot.onMessage(
        (m) async => throw StateError('boom'),
        ackReactions: const AckReactions(),
      );
      final id = await deliver(alice, 'x');
      await until(() => hub.calls('SendReliableDirectFanout').length == 3);
      final t = await transcript(alice);
      expect(t.first, 'react:$id:👀');
      expect(t[1], contains('Sorry'));
      expect(t.last, 'react:$id:❌');
    });

    test('markFailed after an own error text: ❌', () async {
      await bot.onMessage((m) async {
        await m.reply('the model timed out');
        m.markFailed();
      }, ackReactions: const AckReactions());
      final id = await deliver(alice, 'x');
      await until(() => hub.calls('SendReliableDirectFanout').length == 3);
      expect((await transcript(alice)).last, 'react:$id:❌');
    });

    test('the handler\'s finalReaction replaces the default; failure '
        'still wins', () async {
      final emojis = ['🎉', '', 'nope'];
      await bot.onMessage((m) async {
        m.finalReaction = emojis.removeAt(0);
      }, ackReactions: const AckReactions());
      final a = await deliver(alice, 'one');
      await until(() => hub.calls('SendReliableDirectFanout').length == 2);
      final b = await deliver(alice, 'two');
      await until(() => hub.calls('SendReliableDirectFanout').length == 4);
      final c = await deliver(alice, 'three');
      await until(() => hub.calls('SendReliableDirectFanout').length == 6);
      expect(await transcript(alice), [
        'react:$a:👀',
        'react:$a:🎉',
        'react:$b:👀',
        'react:$b:', // '' removes the bot's reaction
        'react:$c:👀',
        'react:$c:👍', // invalid choice: logged, default used
      ]);
      expect(logs.any((l) => l.contains('Invalid final reaction')), isTrue);
    });

    test('a failed receipt is logged and never blocks the turn', () async {
      hub.failures['SendReliableDirectFanout'] = [
        for (var i = 0; i < 3; i++) () => Exception('hub down'),
      ];
      final done = <String>[];
      await bot.onMessage((m) async {
        await m.reply('still here');
        done.add(m.id);
      }, ackReactions: const AckReactions());
      final id = await deliver(alice, 'x');
      await until(() => done.isNotEmpty);
      await until(() => hub.calls('SendReliableDirectFanout').length == 5);
      expect(logs.any((l) => l.contains('Receipt reaction')), isTrue);
      // The three refused attempts carried the same envelope; skip them.
      final calls = hub.calls('SendReliableDirectFanout');
      final ok = calls.skip(3).toList();
      expect(
        await alice.readPayload(
          bot.deviceId,
          (calls.first[3] as Map<String, String>)[alice.id]!,
        ),
        containsPair('type', reactionType),
      );
      final reply = await alice.readPayload(
        bot.deviceId,
        (ok[0][3] as Map<String, String>)[alice.id]!,
      );
      expect(reply['body'], 'still here');
      final last = await alice.readPayload(
        bot.deviceId,
        (ok[1][3] as Map<String, String>)[alice.id]!,
      );
      expect(
        ReactionPayload.decode(last['body']),
        ReactionPayload(targetId: id, emoji: '✅'),
      );
    });

    test('off (no AckReactions): no reaction, finalReaction still '
        'applied', () async {
      var n = 0;
      await bot.onMessage((m) async {
        if (n++ == 1) m.finalReaction = '👍';
        await m.reply('ok');
      });
      await deliver(alice, 'one');
      await until(() => hub.calls('SendReliableDirectFanout').length == 1);
      final b = await deliver(alice, 'two');
      await until(() => hub.calls('SendReliableDirectFanout').length == 3);
      expect(await transcript(alice), ['ok', 'ok', 'react:$b:👍']);
    });

    test('a re-delivered message gets no second receipt', () async {
      final done = <String>[];
      await bot.onMessage(
        (m) async => done.add(m.id),
        ackReactions: const AckReactions(),
      );
      final m = await alice.messageTo(bot.deviceId, api.botBundle, 'x');
      hub.deliver(m);
      await until(() => hub.calls('SendReliableDirectFanout').length == 2);
      hub.deliver(m);
      await until(() => hub.calls('AcknowledgeMessage').length == 2);
      expect(done, hasLength(1));
      expect(hub.calls('SendReliableDirectFanout'), hasLength(2));
    });
  });

  group('nothing for dropped messages', () {
    test('a refused sender, an unaddressed group message, control '
        'messages and reactions get no reaction', () async {
      api.groups[groupId] = [alice.id, bob.id, bot.deviceId];
      final handled = <String>[];
      bot.onReaction((_) async => handled.add('reaction'));
      await bot.onMessage(
        (m) async => handled.add(m.text),
        allowSender: (id) => id != bob.id,
        ackReactions: const AckReactions(),
      );
      await deliver(bob, 'stranger'); // refused before decryption
      await deliver(alice, 'chatter', groupId: groupId); // not addressed
      await deliver(alice, 'x', extra: {'type': pinType});
      await deliver(alice, 'x', extra: {'type': pollVoteType});
      await deliver(alice, 'x', extra: {'type': 'edit', 'editOf': 'm1'});
      await deliver(
        alice,
        const ReactionPayload(targetId: 'm1', emoji: '👍').encode(),
        extra: {'type': reactionType},
      );
      await until(() => hub.calls('AcknowledgeMessage').length == 6);
      await until(() => handled.isNotEmpty);
      expect(handled, ['reaction']);
      expect(hub.calls('SendReliableDirectFanout'), isEmpty);
      expect(hub.calls('SendReliableGroupFanout'), isEmpty);
    });
  });

  group('manual accept (bridges with own access rules)', () {
    test('only accepted messages get the receipt and the final emoji, '
        'incl. a peer bot admitted in a group', () async {
      api.groups[groupId] = [alice.id, bob.id, bot.deviceId];
      api.memberFields[bob.id] = {'isBot': true};
      var admitBots = true;
      final done = <String>[];
      await bot.onMessage(
        (m) async {
          // A bridge's bot-talk rule: here simply a switch.
          if (m.senderIsBot == true && !admitBots) {
            done.add('dropped');
            return;
          }
          await m.accept();
          await m.accept(); // once only
          await m.reply('answer');
          done.add('answered');
        },
        allowSender: (_) => true,
        ackReactions: const AckReactions(manual: true),
      );
      final first = await deliver(bob, '@Hermes ping', groupId: groupId);
      await until(() => done.length == 1);
      await until(() => hub.calls('SendReliableGroupFanout').length == 3);
      expect(await transcript(alice, method: 'SendReliableGroupFanout'), [
        'react:$first:👀',
        'answer',
        'react:$first:✅',
      ]);
      admitBots = false; // bot talk off / limit reached
      await deliver(bob, '@Hermes ping again', groupId: groupId);
      await until(() => done.length == 2);
      await until(() => hub.calls('AcknowledgeMessage').length == 2);
      expect(done.last, 'dropped');
      expect(hub.calls('SendReliableGroupFanout'), hasLength(3));
    });

    test('a handler that never accepts sends nothing', () async {
      final done = <String>[];
      await bot.onMessage(
        (m) async => done.add(m.id),
        ackReactions: const AckReactions(manual: true),
      );
      await deliver(alice, 'x');
      await until(() => hub.calls('AcknowledgeMessage').isNotEmpty);
      expect(done, hasLength(1));
      expect(hub.calls('SendReliableDirectFanout'), isEmpty);
    });
  });

  group('parseReplyDirective / hideReplyDirective', () {
    test('directive line parsed and stripped; reaction-only answer', () {
      final d = parseReplyDirective('[react: 👍]\nDíky!');
      expect(d.emoji, '👍');
      expect(d.text, 'Díky!');
      expect(parseReplyDirective('[react:👍]').text.trim(), isEmpty);
      expect(parseReplyDirective('[react:ok]\nx').invalid, isTrue);
    });

    test('a streamed directive is hidden from progress text', () {
      expect(hideReplyDirective('[react: 👍]\nHello'), 'Hello');
      expect(hideReplyDirective('[rea'), '');
      expect(hideReplyDirective('[react: 👍'), '');
      expect(hideReplyDirective('[reading list] a'), '[reading list] a');
      expect(hideReplyDirective('Hello [react:👍]'), 'Hello [react:👍]');
    });
  });
}
