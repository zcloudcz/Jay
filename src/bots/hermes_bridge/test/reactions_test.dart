import 'dart:io';

import 'package:calltype_bot/calltype_bot.dart';
import 'package:hermes_bridge/hermes_bridge.dart';
import 'package:test/test.dart';

import '../../calltype_bot/test/helpers.dart';

/// Owners' emoji reactions reach Hermes per REACTION_MODE (spec
/// 2026-11-07-message-reactions, section "Bots"). Real crypto, fake hub.
void main() {
  const groupId = '00000000-0000-4000-8000-0000000000c0';
  late Directory dir;
  late FakeApi api;
  late FakeHub hub;
  late FakeUser alice; // owner
  late FakeUser peer; // a bot in the group
  late CallTypeBot bot;
  final prompts = <String>[];
  final approvals = <(String, String, String)>[];
  final logs = <String>[];
  var readSoFar = 0;

  /// Every turn answers at once; a prompt containing "needs approval" first
  /// asks for one.
  Stream<HermesEvent> stream(
    String text, {
    required String conversationId,
  }) async* {
    prompts.add(text);
    if (text.contains('needs approval')) {
      yield const HermesApprovalRequest(
        runId: 'run1',
        requestId: 'req1',
        command: 'rm -rf /',
        description: '',
        choices: ['once', 'deny'],
      );
    }
    yield HermesCompleted('answer ${prompts.length}');
  }

  setUp(() async {
    prompts.clear();
    approvals.clear();
    logs.clear();
    readSoFar = 0;
    dir = await Directory.systemTemp.createTemp('hermes_bridge_reactions');
    api = await FakeApi.start();
    hub = FakeHub();
    alice = await FakeUser.create('00000000-0000-4000-8000-00000000000a');
    peer = await FakeUser.create('00000000-0000-4000-8000-00000000000b');
    api.handles['CT-AAAA-0001'] = alice.id;
    api.keyBundles[alice.id] = await alice.keyBundle();
    api.keyBundles[peer.id] = await peer.keyBundle();
    bot = await CallTypeBot.start(
      apiBaseUrl: api.url,
      storePath: '${dir.path}/bot.store',
      storeKeyBase64: testStoreKey,
      transportFactory: (_, _) => hub,
      log: logs.add,
      sendRetryDelay: Duration.zero,
    );
    api.groups[groupId] = [alice.id, peer.id, bot.deviceId];
    api.memberFields[alice.id] = {'role': 'admin'};
    api.memberFields[peer.id] = {'isBot': true, 'userHandle': 'CT-PEER-0002'};
    api.groupDetails[groupId] = {
      'groupId': groupId,
      'botTalk': {'mode': 'all', 'maxBotTurns': 5},
    };
  });

  tearDown(() async {
    await bot.close();
    await alice.close();
    await peer.close();
    await api.close();
    await dir.delete(recursive: true);
  });

  Future<HermesBridge> start(ReactionMode mode) => runBridge(
    bot,
    allowedHandles: {'CT-AAAA-0001'},
    stream: stream,
    approve: (run, request, choice) async =>
        approvals.add((run, request, choice)),
    progress: ProgressSettings.never,
    reactions: mode,
    log: logs.add,
  );

  int sends() => hub.invocations
      .where(
        (i) =>
            i.method == 'SendReliableDirectFanout' ||
            i.method == 'SendReliableGroupFanout',
      )
      .length;

  /// Payloads alice got since the last call, decrypted in order.
  Future<List<Map<String, dynamic>>> aliceInbox() async {
    final calls = [
      for (final i in hub.invocations)
        if (i.method == 'SendReliableDirectFanout' ||
            i.method == 'SendReliableGroupFanout')
          i.args,
    ];
    final out = <Map<String, dynamic>>[];
    for (final call in calls.skip(readSoFar)) {
      out.add(
        await alice.readPayload(
          bot.deviceId,
          (call[3] as Map<String, String>)[alice.id]!,
        ),
      );
    }
    readSoFar = calls.length;
    return out;
  }

  /// Delivers and waits until the bot acked it (handled or dropped).
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

  Future<void> react(
    FakeUser from,
    String target,
    String emoji, {
    String? group,
  }) => deliver(
    from,
    ReactionPayload(targetId: target, emoji: emoji).encode(),
    group: group,
    extra: {'type': reactionType},
  );

  /// Alice asks, the bot answers; returns the answer's message id.
  Future<String> exchange(String text) async {
    await deliver(alice, text);
    return (await aliceInbox()).last['id'] as String;
  }

  test('parseReactionMode: default silent, names, typo refused', () {
    expect(parseReactionMode(null), ReactionMode.silent);
    expect(parseReactionMode(' '), ReactionMode.silent);
    expect(parseReactionMode('Batch'), ReactionMode.batch);
    expect(parseReactionMode('reply'), ReactionMode.reply);
    expect(parseReactionMode('off'), ReactionMode.off);
    expect(() => parseReactionMode('loud'), throwsFormatException);
  });

  test('silent (default): one turn with the note, nothing posted', () async {
    await start(ReactionMode.silent);
    final answer = await exchange('deploy beta');
    final before = sends();
    await react(alice, answer, '👍');
    expect(prompts.last, startsWith('[from CT-AAAA-0001] '));
    expect(prompts.last, contains('[reaction 👍 to your message: "answer 1"]'));
    expect(prompts.last, contains(silentReactionHint));
    expect(sends(), before, reason: 'no reply loop');
    expect(hub.calls('TypingIndicator').length, 1, reason: 'first turn only');
  });

  test('silent: an approval asked during a reaction turn is denied', () async {
    await start(ReactionMode.silent);
    // The remembered target text reaches the prompt and makes the scripted
    // backend ask for an approval.
    final sent = await bot.send(to: 'CT-AAAA-0001', text: 'needs approval');
    await aliceInbox();
    final before = sends();
    await react(alice, sent.id, '👍');
    expect(approvals, [('run1', 'req1', 'deny')]);
    expect(sends(), before, reason: 'no approval buttons, no answer');
  });

  test('batch: no turn; the notes go in front of the next message', () async {
    await start(ReactionMode.batch);
    final answer = await exchange('status?');
    await react(alice, answer, '👍');
    await react(alice, answer, '🎉');
    expect(prompts, hasLength(1));
    await deliver(alice, 'thanks');
    expect(prompts.last.split('\n'), [
      '[from CT-AAAA-0001] [reaction 👍 to your message: "answer 1"]',
      '[from CT-AAAA-0001] [reaction 🎉 to your message: "answer 1"]',
      '[from CT-AAAA-0001]: thanks',
    ]);
    await deliver(alice, 'again');
    expect(prompts.last, '[from CT-AAAA-0001]: again', reason: 'used once');
  });

  test('reply: the answer is posted to the owner', () async {
    await start(ReactionMode.reply);
    final answer = await exchange('joke?');
    await react(alice, answer, '😂');
    final inbox = await aliceInbox();
    expect(inbox.single['body'], 'answer 2');
    expect(prompts.last, isNot(contains(silentReactionHint)));
  });

  test('off: ignored', () async {
    await start(ReactionMode.off);
    final answer = await exchange('x');
    await react(alice, answer, '👍');
    expect(prompts, hasLength(1));
  });

  test('removals and peer bots\' reactions never reach Hermes', () async {
    await start(ReactionMode.reply);
    final answer = await exchange('x');
    await react(alice, answer, '');
    expect(prompts, hasLength(1));
    final inGroup = await bot.send(to: groupId, text: 'group news');
    await peer.readPayload(
      bot.deviceId,
      (hub.calls('SendReliableGroupFanout').last[3]
          as Map<String, String>)[peer.id]!,
    );
    await react(peer, inGroup.id, '🤖', group: groupId);
    expect(prompts, hasLength(1));
  });

  test(
    'group: an owner\'s reaction to the bot\'s message is forwarded',
    () async {
      await start(ReactionMode.reply);
      final inGroup = await bot.send(to: groupId, text: 'build green');
      await aliceInbox();
      await react(alice, inGroup.id, '🎉', group: groupId);
      expect(
        prompts.single,
        '[from CT-AAAA-0001] [reaction 🎉 to your message: "build green"]',
      );
      final inbox = await aliceInbox();
      expect(inbox.single['groupId'], groupId);
      expect(inbox.single['body'], 'answer 1');
    },
  );

  test('reactionNote without remembered text', () {
    expect(
      reactionNote(
        const BotReaction(
          id: 'r',
          targetId: 't',
          emoji: '👍',
          senderId: 's',
          conversationId: 'c',
          isGroup: false,
        ),
      ),
      '[reaction 👍 to a message]',
    );
  });
}
