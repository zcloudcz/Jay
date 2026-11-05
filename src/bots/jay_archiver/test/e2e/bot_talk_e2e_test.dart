// Live proof of bot conversations (docs/superpowers/specs/2026-11-05-bot-
// conversations-design.md): two real bridges (real calltype_bot runtime,
// real crypto, real hub) with a fake backend, in one group owned by a human
// admin. The group setting goes Off -> Selected (one bot) -> All and the
// exchange limit, the one notice and the local /send path are checked.
// Skipped without JAY_E2E_API. LOCAL compose only, never beta or production.
@Timeout(Duration(minutes: 4))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:calltype_bot/calltype_bot.dart';
import 'package:hermes_bridge/hermes_bridge.dart';
import 'package:test/test.dart';

import 'e2e_device.dart';

/// Every group message the human owner receives, decrypted in arrival order.
class Inbox {
  Inbox(this.device) {
    // WHY a chain: decryption advances the ratchet, so messages from one
    // sender must be processed strictly in order.
    _sub = device.signalR.onMessage.listen((data) {
      _tail = _tail.then((_) => _take(data));
    });
  }

  final E2eDevice device;
  late final StreamSubscription<Map<String, dynamic>> _sub;
  Future<void> _tail = Future.value();
  final messages = <({String sender, String body})>[];

  Future<void> _take(Map<String, dynamic> data) async {
    final senderId = data['senderId'] as String;
    await device.directory.refresh(senderId, ensurePinned: device.ensureSession);
    final plaintext = await device.sessions.decryptMessage(
      senderId,
      utf8.decode(base64Decode(data['encryptedBody'] as String)),
    );
    final payload = jsonDecode(plaintext) as Map<String, dynamic>;
    await device.signalR.acknowledgeMessage(senderId, data['messageId'] as String);
    messages.add((sender: senderId.toLowerCase(), body: payload['body'] as String));
  }

  /// Waits until no new message arrived for [quiet], then returns them all
  /// and starts a fresh list. Bot chatter has no "done" signal, so silence
  /// is the only proof that the bots stopped.
  Future<List<({String sender, String body})>> settle({
    Duration quiet = const Duration(seconds: 5),
  }) async {
    var seen = -1;
    while (seen != messages.length) {
      seen = messages.length;
      await Future<void>.delayed(quiet);
      await _tail;
    }
    final result = List.of(messages);
    messages.clear();
    return result;
  }

  Future<void> close() => _sub.cancel();
}

void main() {
  final baseUrl = Platform.environment['JAY_E2E_API'];

  test(
    'bots talk only as the group setting allows, stop at the limit, notice once',
    skip: baseUrl == null ? 'set JAY_E2E_API to a LOCAL API' : null,
    () async {
      final owner = await E2eDevice.register(baseUrl!);
      final temp = await Directory.systemTemp.createTemp('bot_talk_e2e');
      final storeKey = base64Encode(List<int>.generate(32, (_) => random.nextInt(256)));
      final logs = <String>[];

      Future<CallTypeBot> startBot(String name) => CallTypeBot.start(
        apiBaseUrl: baseUrl,
        storePath: '${temp.path}/$name',
        displayName: name,
        storeKeyBase64: storeKey,
        // Short TTL is only a safety net: the GroupChanged hint is what
        // must make the bots re-read the setting.
        groupCacheTtl: const Duration(minutes: 5),
        log: (line) => logs.add('$name: $line'),
      );
      final botA = await startBot('Alpha');
      final botB = await startBot('Beta');
      addTearDown(() async {
        await Future.wait([botA.close(), botB.close(), owner.close()]);
        await temp.delete(recursive: true);
      });
      await owner.signalR.connect();
      final inbox = Inbox(owner);
      addTearDown(inbox.close);

      // Fake backend: every answer addresses the OTHER bot, so without the
      // rules the two would talk forever.
      var turn = 0;
      Backend talkTo(CallTypeBot other) => (text, {required conversationId}) async =>
          '@${other.handle} turn ${++turn}';
      final bridgeA = await runBridge(
        botA,
        allowedHandles: {owner.handle},
        backend: talkTo(botB),
        log: (line) => logs.add('Alpha: $line'),
      );
      await runBridge(
        botB,
        allowedHandles: {owner.handle},
        backend: talkTo(botA),
        log: (line) => logs.add('Beta: $line'),
      );

      final created = await owner.api.createGroup('bots', [botA.deviceId, botB.deviceId]);
      final groupId = created['groupId'] as String;
      final members = [botA.deviceId, botB.deviceId];
      final a = botA.deviceId.toLowerCase();
      final b = botB.deviceId.toLowerCase();

      Future<void> setting(BotTalkMode mode, {List<String> ids = const [], int turns = 2}) async {
        await owner.api.setGroupBotTalk(
          groupId,
          BotTalkSettings(mode: mode, allowedBotDeviceIds: ids, maxBotTurns: turns, pauseMinutes: 30),
        );
        // The hint travels over the hub; give the bots a moment to drop
        // their cached copy before the next message arrives.
        await Future<void>.delayed(const Duration(seconds: 1));
      }

      int from(List<({String sender, String body})> list, String id) =>
          list.where((m) => m.sender == id).length;

      // 1. A bot may START a message (the local /send path) even while bot
      //    talk is off: rules (a)+(b) are about answering other bots.
      expect(await bridgeA.sendFromLocal(groupId, 'deploy 28f5070 done'), SendOutcome.sent);
      var got = await inbox.settle();
      expect(got.single.sender, a);
      expect(got.single.body, 'deploy 28f5070 done');

      // 2. Off (default): A answers its owner, B ignores A.
      await owner.sendToGroup(groupId, members, '@${botA.handle} start');
      got = await inbox.settle();
      expect(from(got, a), 1, reason: 'A answers the human once');
      expect(from(got, b), 0, reason: 'bot talk is off');

      // 3. Selected with only A: B is not on the list, so it still refuses.
      await setting(BotTalkMode.selected, ids: [botA.deviceId]);
      await owner.sendToGroup(groupId, members, '@${botA.handle} again');
      got = await inbox.settle();
      expect(from(got, a), 1);
      expect(from(got, b), 0, reason: 'B is not selected');

      // 4. All, limit 2: the bots alternate until each has accepted two
      //    turns from the other, then B posts the notice exactly once and
      //    everybody is silent (counting walk-through in the comment of
      //    BotTalkPolicy: A N+1 messages, B N replies + 1 notice).
      await setting(BotTalkMode.all, turns: 2);
      await owner.sendToGroup(groupId, members, '@${botA.handle} talk to Beta');
      got = await inbox.settle();
      expect(from(got, a), 3, reason: got.toString());
      expect(got.where((m) => m.sender == b && m.body == botLimitNotice), hasLength(1),
          reason: got.toString());
      expect(from(got, b), 3, reason: got.toString());

      // 5. Limit reached and the pause (30 min) running: A may not start a
      //    new bot turn via /send either.
      expect(await bridgeA.sendFromLocal(groupId, 'one more'), SendOutcome.forbidden);
      expect(await inbox.settle(quiet: const Duration(seconds: 2)), isEmpty);
    },
  );
}
