import 'dart:async';
import 'dart:io';

import 'package:calltype_bot/calltype_bot.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Agent messaging in the runtime (contract section 5): reply addressing,
/// structured mentions, quotes, buttons, edits, button presses outside the
/// conversation queue, commands, deep links. Real crypto on both ends.
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
    dir = await Directory.systemTemp.createTemp('calltype_bot_agent_test');
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

  /// Delivers one message from [from] and waits for its acknowledgement
  /// (handler finished, or ignored).
  Future<void> deliver(
    FakeUser from,
    String text, {
    String? group,
    Map<String, dynamic> extra = const {},
  }) async {
    final before = hub.calls('AcknowledgeMessage').length;
    hub.deliver(
      await from.messageTo(
        bot.deviceId,
        api.botBundle,
        text,
        groupId: group,
        extra: extra,
      ),
    );
    await until(() => hub.calls('AcknowledgeMessage').length == before + 1);
  }

  /// The payload alice received in the [index]-th send call of [method].
  Future<Map<String, dynamic>> sentToAlice(String method, [int index = -1]) {
    final calls = hub.calls(method);
    final call = calls[index < 0 ? calls.length + index : index];
    return alice.readPayload(
      bot.deviceId,
      (call[3] as Map<String, String>)[alice.id]!,
    );
  }

  group('group addressing', () {
    test('a reply to the bot is handled without @, quoted back', () async {
      final seen = <BotMessage>[];
      await bot.onMessage((m) async {
        seen.add(m);
        await m.reply('answer');
      });
      final long = 'x' * 150;
      await deliver(
        bob,
        long,
        group: groupId,
        extra: {
          'replyTo': {
            'id': 'earlier',
            'senderId': bot.deviceId.toUpperCase(),
            'preview': 'earlier bot text',
          },
        },
      );
      expect(seen.single.repliesToBot, isTrue);
      expect(seen.single.mentionsBot, isFalse);
      expect(seen.single.addressed, isTrue);
      expect(seen.single.replyTo!.preview, 'earlier bot text');

      final payload = await sentToAlice('SendReliableGroupFanout');
      expect(payload['body'], 'answer');
      expect(payload['replyTo'], {
        'id': seen.single.id,
        'senderId': bob.id,
        'preview': 'x' * 100,
      });
    });

    test('a reply to someone else without @ is ignored', () async {
      final seen = <BotMessage>[];
      await bot.onMessage((m) async => seen.add(m));
      await deliver(
        bob,
        'sure',
        group: groupId,
        extra: {
          'replyTo': {'id': 'm', 'senderId': alice.id, 'preview': 'hi'},
        },
      );
      expect(seen, isEmpty);
      expect(hub.calls('SendReliableGroupFanout'), isEmpty);
    });

    test('structured mentions address the bot; others do not', () async {
      final seen = <BotMessage>[];
      await bot.onMessage((m) async => seen.add(m));
      await deliver(
        bob,
        'please look',
        group: groupId,
        extra: {
          'mentions': [alice.id],
        },
      );
      expect(seen, isEmpty);
      await deliver(
        bob,
        'please look',
        group: groupId,
        extra: {
          'mentions': [alice.id, bot.deviceId.toUpperCase(), 7],
        },
      );
      expect(seen.single.mentionsBot, isTrue);
      expect(seen.single.mentions, [alice.id, bot.deviceId.toLowerCase()]);
    });

    test('a malformed replyTo/mentions never drops a 1:1 message', () async {
      final seen = <BotMessage>[];
      await bot.onMessage((m) async => seen.add(m));
      await deliver(
        alice,
        'hi',
        extra: {'replyTo': 'junk', 'mentions': 'junk', 'action': 3},
      );
      expect(seen.single.text, 'hi');
      expect(seen.single.replyTo, isNull);
      expect(seen.single.action, isNull);
    });
  });

  group('sending', () {
    test('a 1:1 reply does not quote', () async {
      await bot.onMessage((m) async => m.reply('pong'));
      await deliver(alice, 'ping');
      final payload = await sentToAlice('SendReliableDirectFanout');
      expect(payload['body'], 'pong');
      expect(payload.containsKey('replyTo'), isFalse);
      expect(payload.containsKey('actions'), isFalse);
    });

    test('reply with buttons, then edits (actions key semantics)', () async {
      final sent = Completer<BotSentMessage>();
      await bot.onMessage((m) async {
        sent.complete(
          await m.reply(
            'Run rm?',
            actions: const [
              MessageButton(id: 'yes', label: 'Yes'),
              MessageButton(id: 'no', label: 'No'),
            ],
          ),
        );
      });
      await deliver(alice, 'clean up');
      final message = await sent.future;
      expect(message.conversationId, alice.id);
      expect(message.groupId, isNull);

      final original = await sentToAlice('SendReliableDirectFanout');
      expect(original['id'], message.id);
      expect(original['type'], 'text');
      expect(original['actions'], [
        {'id': 'yes', 'label': 'Yes'},
        {'id': 'no', 'label': 'No'},
      ]);

      await message.edit('Still thinking');
      var edit = await sentToAlice('SendReliableDirectFanout');
      expect(edit['type'], 'edit');
      expect(edit['editOf'], message.id);
      expect(edit['body'], 'Still thinking');
      expect(edit['id'], isNot(message.id));
      expect(edit['to'], alice.id);
      expect(edit.containsKey('actions'), isFalse); // null = keep buttons

      await message.edit('Done', actions: const []);
      edit = await sentToAlice('SendReliableDirectFanout');
      expect(edit['actions'], isEmpty); // [] = remove buttons
      expect(
        DateTime.parse(
          edit['createdAt'] as String,
        ).isAfter(DateTime.parse(original['createdAt'] as String)),
        isTrue,
      );
    });

    test(
      'send() returns the sent message; group edit keeps the group',
      () async {
        await bot.onMessage((_) async {});
        final message = await bot.send(
          to: groupId,
          text: 'deploy?',
          actions: const [MessageButton(id: 'go', label: 'Go')],
        );
        expect(message.groupId, groupId);
        final payload = await sentToAlice('SendReliableGroupFanout');
        expect(payload['id'], message.id);
        expect(payload['actions'], [
          {'id': 'go', 'label': 'Go'},
        ]);
        await message.edit('deployed', actions: const []);
        final edit = await sentToAlice('SendReliableGroupFanout');
        expect(edit['groupId'], groupId);
        expect(edit['editOf'], message.id);
      },
    );

    test('invalid buttons are refused before anything is sent', () async {
      await bot.onMessage((_) async {});
      await expectLater(
        bot.send(
          to: 'CT-AAAA-0001',
          text: 'x',
          actions: const [MessageButton(id: 'has space', label: 'L')],
        ),
        throwsArgumentError,
      );
      await expectLater(
        bot.send(
          to: 'CT-AAAA-0001',
          text: 'x',
          actions: [
            for (var i = 0; i < 9; i++) MessageButton(id: 'b$i', label: 'B'),
          ],
        ),
        throwsArgumentError,
      );
      expect(hub.calls('SendReliableDirectFanout'), isEmpty);
    });
  });

  group('button presses', () {
    test('reach onAction while the conversation handler is blocked', () async {
      final release = Completer<void>();
      final buttonMessage = Completer<BotSentMessage>();
      final handled = <String>[];
      final actions = <BotMessage>[];
      await bot.onMessage((m) async {
        handled.add(m.text);
        if (m.text == 'risky') {
          buttonMessage.complete(
            await m.reply(
              'Approve?',
              actions: const [MessageButton(id: 'ok', label: 'Approve')],
            ),
          );
          await release.future; // like a bridge waiting for the approval
        }
      });
      bot.onAction((m) async {
        actions.add(m);
        await m.reply('approved');
      });

      hub.deliver(await alice.messageTo(bot.deviceId, api.botBundle, 'risky'));
      final sent = await buttonMessage.future;
      await deliver(
        alice,
        'Approve',
        extra: {
          'replyTo': {'id': sent.id, 'senderId': bot.deviceId, 'preview': 'x'},
          'action': {'messageId': sent.id, 'id': 'ok'},
        },
      );
      expect(actions.single.action!.id, 'ok');
      expect(actions.single.action!.messageId, sent.id);
      expect(handled, ['risky']); // the press did not go to the queue
      expect(
        await sentToAlice('SendReliableDirectFanout'),
        containsPair('body', 'approved'),
      );
      release.complete();
      await until(() => hub.calls('AcknowledgeMessage').length == 2);
    });

    test(
      'a press on a message the bot did not send goes to the handler',
      () async {
        final handled = <BotMessage>[];
        final actions = <BotMessage>[];
        await bot.onMessage((m) async => handled.add(m));
        bot.onAction((m) async => actions.add(m));
        await deliver(
          alice,
          'Yes',
          extra: {
            'action': {'messageId': 'not-ours', 'id': 'yes'},
          },
        );
        expect(actions, isEmpty);
        expect(handled.single.action!.id, 'yes');
      },
    );

    test('without onAction a press goes to the normal handler', () async {
      final handled = <BotMessage>[];
      await bot.onMessage((m) async {
        handled.add(m);
        if (m.text == 'ask') {
          await m.reply(
            '?',
            actions: const [MessageButton(id: 'a', label: 'A')],
          );
        }
      });
      await deliver(alice, 'ask');
      final id = (await sentToAlice('SendReliableDirectFanout'))['id'];
      await deliver(
        alice,
        'A',
        extra: {
          'action': {'messageId': id, 'id': 'a'},
        },
      );
      expect(handled.map((m) => m.text), ['ask', 'A']);
    });

    test('own button messages are remembered across a restart', () async {
      await bot.onMessage((_) async {});
      final sent = await bot.send(
        to: 'CT-AAAA-0001',
        text: 'Approve?',
        actions: const [MessageButton(id: 'ok', label: 'OK')],
      );
      // Alice must decrypt the first message to have a session with the bot.
      await sentToAlice('SendReliableDirectFanout');
      await bot.close();

      bot = await startBot();
      final actions = <BotMessage>[];
      bot.onAction((m) async => actions.add(m));
      await bot.onMessage((_) async => fail('press must go to onAction'));
      await deliver(
        alice,
        'OK',
        extra: {
          'action': {'messageId': sent.id, 'id': 'ok'},
        },
      );
      expect(actions, hasLength(1));
    });
  });

  test('edits from others are acknowledged and ignored', () async {
    final seen = <BotMessage>[];
    await bot.onMessage((m) async => seen.add(m));
    await deliver(alice, 'changed', extra: {'type': 'edit', 'editOf': 'm1'});
    expect(seen, isEmpty);
    expect(hub.calls('SendReliableDirectFanout'), isEmpty);
  });

  test('setCommands publishes the list through the API', () async {
    await bot.setCommands(const [
      BotCommand(command: 'help', description: 'Show help'),
    ]);
    expect(api.requests, contains('PUT /devices/${bot.deviceId}/bot-commands'));
    expect(api.botCommands[bot.deviceId], {
      'commands': [
        {'command': 'help', 'description': 'Show help'},
      ],
    });
  });

  test('deepLink format and payload validation', () {
    expect(bot.deepLink(), 'calltype://bot/${FakeApi.botHandle}');
    expect(
      bot.deepLink(start: 'ref_42-a'),
      'calltype://bot/${FakeApi.botHandle}?start=ref_42-a',
    );
    expect(() => bot.deepLink(start: ''), throwsArgumentError);
    expect(() => bot.deepLink(start: 'a b'), throwsArgumentError);
    expect(() => bot.deepLink(start: 'x' * 65), throwsArgumentError);
  });
}
