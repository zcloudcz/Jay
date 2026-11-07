import 'dart:convert';
import 'dart:io';

import 'package:calltype_bot/calltype_bot.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Chat extras in the runtime (spec 2026-11-08-chat-extras, compatibility):
/// pins and votes are acked and ignored, a poll is a text message with the
/// parsed poll attached.
void main() {
  late Directory dir;
  late FakeApi api;
  late FakeHub hub;
  late FakeUser alice;
  late CallTypeBot bot;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('calltype_bot_extras_test');
    api = await FakeApi.start();
    alice = await FakeUser.create('00000000-0000-4000-8000-00000000000a');
    api.keyBundles[alice.id] = await alice.keyBundle();
    hub = FakeHub();
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
    await api.close();
    await dir.delete(recursive: true);
  });

  Future<void> deliver(String body, Map<String, dynamic> extra) async {
    final before = hub.calls('AcknowledgeMessage').length;
    hub.deliver(
      await alice.messageTo(bot.deviceId, api.botBundle, body, extra: extra),
    );
    await until(() => hub.calls('AcknowledgeMessage').length == before + 1);
  }

  test('pin and poll-vote are acked and never reach the handler', () async {
    final messages = <BotMessage>[];
    await bot.onMessage((m) async => messages.add(m));
    await deliver(jsonEncode({'targetId': 'm1', 'pinned': true}), {
      'type': pinType,
    });
    await deliver(
      jsonEncode({
        'pollId': 'p1',
        'options': [0],
      }),
      {'type': pollVoteType},
    );
    expect(messages, isEmpty);
    expect(hub.calls('AcknowledgeMessage'), hasLength(2));
    expect(hub.calls('SendReliableDirectFanout'), isEmpty);
  });

  test('a poll arrives as its fallback text with the poll attached', () async {
    final messages = <BotMessage>[];
    await bot.onMessage((m) async => messages.add(m));
    final poll = PollPayload.create(
      question: 'Lunch?',
      options: ['Pizza', 'Sushi'],
    );
    final fallback = poll.fallbackText('(Update Jay to vote in this poll.)');
    await deliver(fallback, {pollKey: poll.toJson()});
    await until(() => messages.isNotEmpty);
    expect(messages.single.text, fallback);
    expect(messages.single.poll, poll);

    await deliver('plain', {
      pollKey: {'v': 9},
    });
    await until(() => messages.length == 2);
    expect(messages.last.poll, isNull, reason: 'invalid poll: text only');
  });
}
