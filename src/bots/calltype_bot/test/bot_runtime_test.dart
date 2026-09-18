import 'dart:async';
import 'dart:io';

import 'package:calltype_bot/calltype_bot.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Runtime tests with TWO real crypto stacks: a [FakeUser] built on the real
/// calltype_core SessionManager talks to the bot through a fake hub + a
/// loopback REST fake. No real server: the API needs PostgreSQL (Docker).
void main() {
  late Directory dir;
  late FakeApi api;
  late FakeHub hub;
  late FakeUser alice;
  final bots = <CallTypeBot>[];
  final logs = <String>[];

  Future<CallTypeBot> startBot() async {
    hub = FakeHub();
    final bot = await CallTypeBot.start(
      apiBaseUrl: api.url,
      storePath: '${dir.path}/bot.store',
      storeKeyBase64: testStoreKey,
      displayName: 'Hermes',
      transportFactory: (_, _) => hub,
      log: logs.add,
      sendRetryDelay: Duration.zero,
    );
    bots.add(bot);
    return bot;
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('calltype_bot_test');
    api = await FakeApi.start();
    alice = await FakeUser.create('00000000-0000-4000-8000-00000000000a');
    api.keyBundles[alice.id] = await alice.keyBundle();
    logs.clear();
  });

  tearDown(() async {
    for (final bot in bots) {
      await bot.close();
    }
    bots.clear();
    await alice.close();
    await api.close();
    await dir.delete(recursive: true);
  });

  test('first start registers as a bot and prints handle + invite', () async {
    final bot = await startBot();
    expect(api.registrations.single['isBot'], isTrue);
    expect(bot.handle, FakeApi.botHandle);
    expect(logs.join('\n'), contains(FakeApi.botHandle));
    expect(logs.join('\n'), contains('ct://${FakeApi.botId}/'));
  });

  test('pre-key message -> handler -> encrypted reply, typing, ack last', () async {
    final bot = await startBot();
    final seen = <BotMessage>[];
    await bot.onMessage((msg) async {
      seen.add(msg);
      // Ack must not have happened while the handler is still running.
      expect(hub.calls('AcknowledgeMessage'), isEmpty);
      await msg.reply('echo: ${msg.text}');
    });

    hub.deliver(await alice.messageTo(bot.deviceId, api.botBundle, 'hi'));
    await until(() => hub.calls('AcknowledgeMessage').isNotEmpty);

    expect(seen.single.text, 'hi');
    expect(seen.single.isGroup, isFalse);
    expect(seen.single.conversationId, alice.id);
    expect(hub.calls('TypingIndicator').first, [alice.id]);
    final sent = hub.calls('SendReliableMessage').single;
    expect(sent[0], alice.id);
    expect(await alice.read(bot.deviceId, sent[2] as String), 'echo: hi');
    expect(hub.calls('AcknowledgeMessage').single, [alice.id, seen.single.id]);
  });

  test('replayed message never reaches the handler twice, even after restart', () async {
    var bot = await startBot();
    var handled = 0;
    await bot.onMessage((msg) async => handled++);

    final delivery = await alice.messageTo(bot.deviceId, api.botBundle, 'once');
    hub.deliver(delivery);
    hub.deliver(delivery);
    await until(() => hub.calls('AcknowledgeMessage').length == 2);
    expect(handled, 1);

    // Restart on the same store: same identity, no second registration.
    await bot.close();
    bots.clear();
    bot = await startBot();
    expect(api.registrations, hasLength(1));
    await bot.onMessage((msg) async {
      handled++;
      await msg.reply('still me');
    });

    hub.deliver(delivery);
    await until(() => hub.calls('AcknowledgeMessage').length == 1);
    expect(handled, 1, reason: 'replay after restart must only be acked');

    // The session survived the restart: a follow-up decrypts and the reply
    // is readable by the user (no identity / safety-number change).
    hub.deliver(await alice.messageTo(bot.deviceId, api.botBundle, 'again'));
    await until(() => hub.calls('SendReliableMessage').isNotEmpty);
    expect(handled, 2);
    final sent = hub.calls('SendReliableMessage').single;
    expect(await alice.read(bot.deviceId, sent[2] as String), 'still me');
  });

  test('handler exception -> apology reply, ack, loop survives', () async {
    final bot = await startBot();
    await bot.onMessage((msg) async {
      if (msg.text == 'boom') throw StateError('backend down');
      await msg.reply('ok');
    });

    hub.deliver(await alice.messageTo(bot.deviceId, api.botBundle, 'boom'));
    hub.deliver(await alice.messageTo(bot.deviceId, api.botBundle, 'fine'));
    await until(() => hub.calls('AcknowledgeMessage').length == 2);

    final replies = [
      for (final sent in hub.calls('SendReliableMessage'))
        await alice.read(bot.deviceId, sent[2] as String),
    ];
    expect(replies, [startsWith('Sorry'), 'ok']);
    expect(logs.join('\n'), contains('backend down'));
  });

  test('handlers are serial per conversation, parallel across them', () async {
    final bob = await FakeUser.create('00000000-0000-4000-8000-00000000000b');
    addTearDown(bob.close);
    final bot = await startBot();
    final started = <String>[];
    final gate = Completer<void>();
    addTearDown(() => gate.isCompleted ? null : gate.complete());
    await bot.onMessage((msg) async {
      started.add(msg.text);
      if (msg.text == 'a1') await gate.future;
    });

    hub.deliver(await alice.messageTo(bot.deviceId, api.botBundle, 'a1'));
    hub.deliver(await alice.messageTo(bot.deviceId, api.botBundle, 'a2'));
    hub.deliver(await bob.messageTo(bot.deviceId, api.botBundle, 'b1'));
    await until(() => started.contains('b1'));
    // Bob was served while Alice's first handler is still blocked …
    expect(started, ['a1', 'b1']);
    gate.complete();
    // … and Alice's second message starts only after her first finished.
    await until(() => started.length == 3);
    expect(started.last, 'a2');
  });

  test('group: silent without a mention, replies to every member with one', () async {
    const groupId = '00000000-0000-4000-8000-0000000000c0';
    final bob = await FakeUser.create('00000000-0000-4000-8000-00000000000b');
    addTearDown(bob.close);
    api.keyBundles[bob.id] = await bob.keyBundle();
    final bot = await startBot();
    api.groups[groupId] = [alice.id, bob.id, bot.deviceId];
    final seen = <BotMessage>[];
    await bot.onMessage((msg) async {
      seen.add(msg);
      await msg.reply('pong');
    });

    hub.deliver(
      await alice.messageTo(bot.deviceId, api.botBundle, 'hello all', groupId: groupId),
    );
    await until(() => hub.calls('AcknowledgeMessage').length == 1);
    expect(seen, isEmpty);
    expect(hub.calls('TypingIndicator'), isEmpty);

    hub.deliver(
      await alice.messageTo(bot.deviceId, api.botBundle, '@hermes ping', groupId: groupId),
    );
    await until(() => hub.calls('AcknowledgeMessage').length == 2);
    expect(seen.single.isGroup, isTrue);
    expect(seen.single.mentionsBot, isTrue);
    expect(seen.single.conversationId, groupId);

    final sends = hub.calls('SendReliableGroupMessage');
    // ONE call for the whole group: a business group's hub rejects any call
    // that lacks the auditor's envelope (KB2), so per-recipient calls would
    // make the bot mute there.
    expect(sends, hasLength(1));
    final recipients = {
      for (final s in sends) ...(s[2] as Map<String, String>).keys,
    };
    expect(recipients, {alice.id, bob.id});
    // Bob never talked to the bot: his copy is a pre-key message that his
    // real stack can establish a session from.
    final bobCopy = sends
        .map((s) => s[2] as Map<String, String>)
        .firstWhere((m) => m.containsKey(bob.id))[bob.id]!;
    expect(await bob.read(bot.deviceId, bobCopy), 'pong');
  });

  test('disallowed sender: acked and dropped, no typing, no handler', () async {
    final bot = await startBot();
    var handled = 0;
    await bot.onMessage((msg) async => handled++, allowSender: (id) => false);

    hub.deliver(await alice.messageTo(bot.deviceId, api.botBundle, 'rm -rf /'));
    await until(() => hub.calls('AcknowledgeMessage').isNotEmpty);

    expect(handled, 0);
    expect(hub.calls('TypingIndicator'), isEmpty);
    expect(hub.calls('SendReliableMessage'), isEmpty);
  });

  test('undecryptable message is not acked and does not stop the loop', () async {
    final bot = await startBot();
    var handled = 0;
    await bot.onMessage((msg) async => handled++);

    hub.deliver({
      'senderId': alice.id,
      'messageId': 'garbage',
      'groupId': null,
      'encryptedBody': 'bm90IGpzb24=',
    });
    hub.deliver(await alice.messageTo(bot.deviceId, api.botBundle, 'real'));
    await until(() => handled == 1);
    await until(() => hub.calls('AcknowledgeMessage').isNotEmpty);

    expect(hub.calls('AcknowledgeMessage').map((a) => a[1]), isNot(contains('garbage')));
  });

  test('deviceIdForHandle resolves known handles, null otherwise', () async {
    final bot = await startBot();
    api.handles['CT-AAAA-0001'] = alice.id;
    expect(await bot.deviceIdForHandle('CT-AAAA-0001'), alice.id);
    expect(await bot.deviceIdForHandle('CT-NOPE-0000'), isNull);
  });
}
