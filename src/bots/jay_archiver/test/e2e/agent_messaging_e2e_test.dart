// Live proof of agent messaging (docs/superpowers/specs/2026-11-05-agent-
// messaging-contract.md, sections 1, 4 and 5): a real bot (calltype_bot
// runtime, real crypto, real hub) and a human device in one group, against a
// real API. Checks bot commands, structured mentions, reply-to addressing,
// buttons, a press handled while the conversation handler still waits for
// it, and the bot's edit. Skipped without JAY_E2E_API. LOCAL compose only,
// never beta or production.
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:calltype_bot/calltype_bot.dart';
import 'package:test/test.dart';

import 'e2e_device.dart';

/// Every message the human receives from the group, as full payloads.
class PayloadInbox {
  PayloadInbox(this.device) {
    // WHY a chain: decryption advances the ratchet, so messages from one
    // sender must be processed strictly in order.
    _sub = device.signalR.onMessage.listen((data) {
      _tail = _tail.then((_) => _take(data));
    });
  }

  final E2eDevice device;
  late final StreamSubscription<Map<String, dynamic>> _sub;
  Future<void> _tail = Future.value();
  final _waiters = <Completer<Map<String, dynamic>>>[];
  final _queue = <Map<String, dynamic>>[];

  Future<void> _take(Map<String, dynamic> data) async {
    final senderId = data['senderId'] as String;
    await device.directory.refresh(senderId, ensurePinned: device.ensureSession);
    final plaintext = await device.sessions.decryptMessage(
      senderId,
      utf8.decode(base64Decode(data['encryptedBody'] as String)),
    );
    await device.signalR.acknowledgeMessage(senderId, data['messageId'] as String);
    final payload = jsonDecode(plaintext) as Map<String, dynamic>;
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(payload);
    } else {
      _queue.add(payload);
    }
  }

  Future<Map<String, dynamic>> next() {
    if (_queue.isNotEmpty) return Future.value(_queue.removeAt(0));
    final c = Completer<Map<String, dynamic>>();
    _waiters.add(c);
    return c.future.timeout(const Duration(seconds: 20));
  }

  /// Proves silence: nothing arrives within [quiet].
  Future<void> expectNothing({Duration quiet = const Duration(seconds: 4)}) async {
    await Future<void>.delayed(quiet);
    await _tail;
    expect(_queue, isEmpty, reason: 'unexpected message(s): $_queue');
  }

  Future<void> close() => _sub.cancel();
}

void main() {
  final baseUrl = Platform.environment['JAY_E2E_API'];

  test(
    'commands, mentions, reply addressing, buttons, press outside the queue, edit',
    skip: baseUrl == null ? 'set JAY_E2E_API to a LOCAL API' : null,
    () async {
      final human = await E2eDevice.register(baseUrl!);
      final temp = await Directory.systemTemp.createTemp('agent_msg_e2e');
      final bot = await CallTypeBot.start(
        apiBaseUrl: baseUrl,
        storePath: '${temp.path}/bot',
        displayName: 'Agent',
        storeKeyBase64: base64Encode(List<int>.generate(32, (_) => random.nextInt(256))),
      );
      addTearDown(() async {
        await Future.wait([bot.close(), human.close()]);
        await temp.delete(recursive: true);
      });

      // --- Section 4: bot commands --------------------------------------
      await bot.setCommands([
        BotCommand(command: 'help', description: 'Show help'),
        BotCommand(command: 'approve', description: 'Ask for approval'),
      ]);
      final read = await human.api.getBotCommands(bot.deviceId);
      expect([for (final c in read) '${c.command}:${c.description}'],
          ['help:Show help', 'approve:Ask for approval']);
      // Only the bot itself may publish its menu.
      await expectLater(
        human.api.setBotCommands(bot.deviceId, [BotCommand(command: 'x', description: 'y')]),
        throwsA(anything),
      );
      expect(bot.deepLink(start: 'abc'), 'calltype://bot/${bot.handle}?start=abc');

      // --- Bot behaviour --------------------------------------------------
      final handled = <String>[];
      final pressed = Completer<BotMessage>();
      bot.onAction((message) async {
        pressed.complete(message);
      });
      await bot.onMessage((message) async {
        handled.add(message.text);
        if (message.text == 'approve please') {
          final sent = await message.reply('Approve?', actions: [
            MessageButton(id: 'approve:1', label: 'Approve'),
            MessageButton(id: 'deny:1', label: 'Deny'),
          ]);
          // WHY wait here: this is the approval shape. The press must reach
          // onAction although this conversation's handler is still running.
          final press = await pressed.future.timeout(const Duration(seconds: 20));
          await sent.edit('Result: ${press.action!.id}', actions: const []);
          return;
        }
        await message.reply('got: ${message.text}');
      }, allowSender: (id) => id.toLowerCase() == human.id.toLowerCase());

      await human.signalR.connect();
      final inbox = PayloadInbox(human);
      addTearDown(inbox.close);
      final created = await human.api.createGroup('agents', [bot.deviceId]);
      final groupId = created['groupId'] as String;
      final members = [bot.deviceId];
      final botId = bot.deviceId.toLowerCase();

      // 1. Not addressed: the bot stays silent in a group.
      await human.sendToGroup(groupId, members, 'hello everybody');
      await inbox.expectNothing();

      // 2. Structured mention without any @text: addressed, and the group
      //    reply quotes the message it answers.
      final askId = await human.sendToGroup(groupId, members, 'approve please',
          extra: {'mentions': [botId]});
      final buttons = await inbox.next();
      expect(buttons['body'], 'Approve?');
      expect(buttons['replyTo']['id'], askId);
      expect((buttons['replyTo']['senderId'] as String).toLowerCase(), human.id.toLowerCase());
      expect(buttons['replyTo']['preview'], 'approve please');
      expect(buttons['actions'], [
        {'id': 'approve:1', 'label': 'Approve'},
        {'id': 'deny:1', 'label': 'Deny'},
      ]);
      final buttonMessageId = buttons['id'] as String;

      // 3. A plain reply to the bot's message (no mention) addresses it, but
      //    the conversation is still busy waiting for the press, so this
      //    answer comes only after the press below.
      final replyRef = {'id': buttonMessageId, 'senderId': botId, 'preview': 'Approve?'};
      await human.sendToGroup(groupId, members, 'thanks', extra: {'replyTo': replyRef});

      // 4. Button press: label as body + replyTo + action. Handled outside
      //    the busy conversation queue; the bot edits its button message.
      await human.sendToGroup(groupId, members, 'Approve', extra: {
        'replyTo': replyRef,
        'action': {'messageId': buttonMessageId, 'id': 'approve:1'},
      });
      final edit = await inbox.next();
      expect(edit['type'], 'edit');
      expect(edit['editOf'], buttonMessageId);
      expect(edit['body'], 'Result: approve:1');
      expect(edit['actions'], isEmpty);
      expect(DateTime.parse(edit['createdAt'] as String)
          .isAfter(DateTime.parse(buttons['createdAt'] as String)), isTrue);

      final thanks = await inbox.next();
      expect(thanks['body'], 'got: thanks');
      expect(thanks['replyTo']['preview'], 'thanks');
      await inbox.expectNothing();
      expect(handled, ['approve please', 'thanks']);
    },
  );
}
