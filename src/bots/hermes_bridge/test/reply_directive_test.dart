import 'dart:async';
import 'dart:io';

import 'package:calltype_bot/calltype_bot.dart';
import 'package:hermes_bridge/hermes_bridge.dart';
import 'package:test/test.dart';

import '../../calltype_bot/test/helpers.dart';

/// The `[react:EMOJI]` reply directive and the local /react path (spec
/// 2026-11-07-message-reactions, section "Bots").
void main() {
  group('parseReplyDirective', () {
    test('plain text is untouched', () {
      for (final text in ['hello', '', '  two\nlines ', '[react] no colon']) {
        final d = parseReplyDirective(text);
        expect(d.emoji, isNull);
        expect(d.text, text);
        expect(d.invalid, isFalse);
      }
    });

    test('directive + text: emoji parsed, first line stripped', () {
      final d = parseReplyDirective('[react:👍]\nDone, deployed.\nsecond');
      expect(d.emoji, '👍');
      expect(d.text, 'Done, deployed.\nsecond');
      expect(d.invalid, isFalse);
    });

    test('whitespace and case are tolerated, CRLF too', () {
      final d = parseReplyDirective('  [ REACT : 🎉 ]  \r\n\r\nYes.');
      expect(d.emoji, '🎉');
      expect(d.text, 'Yes.');
    });

    test('directive only: no text left', () {
      final d = parseReplyDirective('[react:❤️]');
      expect(d.emoji, '❤️');
      expect(d.text.trim(), isEmpty);
      expect(parseReplyDirective('[react:👍]\n\n  \n').text.trim(), isEmpty);
    });

    test('empty emoji means remove', () {
      final d = parseReplyDirective('[react:]\nok');
      expect(d.emoji, '');
      expect(d.text, 'ok');
      expect(parseReplyDirective('[react: ]').emoji, '');
    });

    test('leading blank lines before the directive are skipped', () {
      final d = parseReplyDirective('\n  \n[react:👀]\nLooking.');
      expect(d.emoji, '👀');
      expect(d.text, 'Looking.');
    });

    test('invalid emoji: stripped, flagged, no emoji', () {
      for (final bad in ['ok', '👍👍', 'thumbs up', '1']) {
        final d = parseReplyDirective('[react:$bad]\nText');
        expect(d.emoji, isNull, reason: bad);
        expect(d.invalid, isTrue, reason: bad);
        expect(d.text, 'Text', reason: bad);
      }
    });

    test('a directive that is not on the first line is NOT parsed', () {
      const text = 'Use it like this:\n[react:👍]\nthat is all';
      final d = parseReplyDirective(text);
      expect(d.emoji, isNull);
      expect(d.text, text);
      expect(d.invalid, isFalse);
    });

    test('text after the directive on the same line is not a directive', () {
      const text = '[react:👍] Done.';
      expect(parseReplyDirective(text).emoji, isNull);
      expect(parseReplyDirective(text).text, text);
    });

    test('multi-codepoint emojis', () {
      for (final emoji in [
        '👍🏽',
        '❤️',
        '👨‍👩‍👧',
        '🇨🇿',
        '🏴󠁧󠁢󠁳󠁣󠁴󠁿',
        '1️⃣',
      ]) {
        final d = parseReplyDirective('[react:$emoji]\nx');
        expect(d.emoji, emoji, reason: emoji);
        expect(d.text, 'x');
      }
    });
  });

  group('bridge', () {
    const groupId = '00000000-0000-4000-8000-0000000000c0';
    late Directory dir;
    late FakeApi api;
    late FakeHub hub;
    late FakeUser alice; // owner
    late FakeUser bob; // not an owner
    late CallTypeBot bot;
    final prompts = <String>[];
    final logs = <String>[];
    final answers = <String>[];
    var readSoFar = 0;

    /// Answers with the next of [answers] (or "answer N"), after [gate].
    Completer<void>? gate;
    Stream<HermesEvent> stream(
      String text, {
      required String conversationId,
    }) async* {
      prompts.add(text);
      await gate?.future;
      yield HermesCompleted(
        answers.isEmpty ? 'answer ${prompts.length}' : answers.removeAt(0),
      );
    }

    setUp(() async {
      prompts.clear();
      logs.clear();
      answers.clear();
      gate = null;
      readSoFar = 0;
      dir = await Directory.systemTemp.createTemp('hermes_bridge_directive');
      api = await FakeApi.start();
      hub = FakeHub();
      alice = await FakeUser.create('00000000-0000-4000-8000-00000000000a');
      bob = await FakeUser.create('00000000-0000-4000-8000-00000000000b');
      api.handles['CT-AAAA-0001'] = alice.id;
      api.handles['CT-BBBB-0002'] = bob.id;
      api.keyBundles[alice.id] = await alice.keyBundle();
      api.keyBundles[bob.id] = await bob.keyBundle();
      bot = await CallTypeBot.start(
        apiBaseUrl: api.url,
        storePath: '${dir.path}/bot.store',
        storeKeyBase64: testStoreKey,
        transportFactory: (_, _) => hub,
        log: logs.add,
        sendRetryDelay: Duration.zero,
      );
      api.groups[groupId] = [alice.id, bob.id, bot.deviceId];
      api.groupDetails[groupId] = {
        'groupId': groupId,
        'botTalk': {'mode': 'off'},
      };
    });

    tearDown(() async {
      await bot.close();
      await alice.close();
      await bob.close();
      await api.close();
      await dir.delete(recursive: true);
    });

    Future<HermesBridge> start({
      ProgressSettings progress = ProgressSettings.never,
      ReactionMode reactions = ReactionMode.silent,
    }) => runBridge(
      bot,
      allowedHandles: {'CT-AAAA-0001'},
      stream: stream,
      progress: progress,
      reactions: reactions,
      log: logs.add,
    );

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

    /// Alice sends [text]; waits until the bot acknowledged it. Returns the
    /// message id.
    Future<String> say(String text, {String? group, String? id}) async {
      final before = hub.calls('AcknowledgeMessage').length;
      final message = await alice.messageTo(
        bot.deviceId,
        api.botBundle,
        group == null ? text : '@${bot.handle} $text',
        groupId: group,
        messageId: id,
      );
      hub.deliver(message);
      await until(() => hub.calls('AcknowledgeMessage').length == before + 1);
      return message['messageId'] as String;
    }

    ReactionPayload? reactionOf(Map<String, dynamic> payload) =>
        payload['type'] == reactionType
        ? ReactionPayload.decode(payload['body'])
        : null;

    test('the first owner message carries the directive hint', () async {
      await start();
      await say('hi');
      expect(prompts.single, startsWith('$reactDirectiveHint\n[from '));
    });

    test(
      'directive + text: reacts to the answered message, posts the rest',
      () async {
        await start();
        answers.add('[react:👍]\nDeployed.');
        final id = await say('deploy please');
        final inbox = await aliceInbox();
        expect(inbox, hasLength(2));
        expect(
          reactionOf(inbox[0]),
          ReactionPayload(targetId: id, emoji: '👍'),
        );
        expect(inbox[0]['to'], alice.id);
        expect(inbox[1]['type'], 'text');
        expect(inbox[1]['body'], 'Deployed.');
      },
    );

    test('directive only: a reaction and no text message', () async {
      await start();
      answers.add('[react:🎉]');
      final id = await say('it works now');
      final inbox = await aliceInbox();
      expect(inbox, hasLength(1));
      expect(
        reactionOf(inbox.single),
        ReactionPayload(targetId: id, emoji: '🎉'),
      );
    });

    test('[react:] removes the bot\'s reaction', () async {
      await start();
      answers.add('[react:]\nRemoved.');
      final id = await say('undo');
      final inbox = await aliceInbox();
      expect(reactionOf(inbox[0]), ReactionPayload(targetId: id, emoji: ''));
      expect(inbox[1]['body'], 'Removed.');
    });

    test('invalid directive: stripped and logged, text still posted', () async {
      await start();
      answers.add('[react:thumbs]\nHello.');
      await say('hi');
      final inbox = await aliceInbox();
      expect(inbox.single['type'], 'text');
      expect(inbox.single['body'], 'Hello.');
      expect(
        logs.where((l) => l.contains('Invalid reply directive')),
        hasLength(1),
      );
    });

    test('a directive in a group reacts in the group', () async {
      await start();
      answers.add('[react:👀]\nOn it.');
      final id = await say('check', group: groupId);
      final inbox = await aliceInbox();
      expect(inbox[0]['groupId'], groupId);
      expect(reactionOf(inbox[0]), ReactionPayload(targetId: id, emoji: '👀'));
      expect(inbox[1]['body'], 'On it.');
    });

    test('directive only after a progress message: the progress message '
        'becomes "Done."', () async {
      await start(
        progress: const ProgressSettings(after: Duration(milliseconds: 20)),
      );
      gate = Completer<void>();
      answers.add('[react:👍]');
      final message = await alice.messageTo(bot.deviceId, api.botBundle, 'go');
      hub.deliver(message);
      await until(() => hub.calls('SendReliableDirectFanout').isNotEmpty);
      gate!.complete();
      await until(() => hub.calls('AcknowledgeMessage').isNotEmpty);
      final inbox = await aliceInbox();
      expect(inbox.map((p) => p['type']), ['text', reactionType, 'edit']);
      expect(inbox[0]['body'], startsWith('Working on it'));
      expect(
        reactionOf(inbox[1]),
        ReactionPayload(targetId: message['messageId'] as String, emoji: '👍'),
      );
      expect(inbox[2]['editOf'], inbox[0]['id']);
      expect(inbox[2]['body'], reactedProgressText);
    });

    test('silent reaction turns never react', () async {
      await start();
      await say('hi');
      await aliceInbox();
      final sentId = (await bot.send(to: 'CT-AAAA-0001', text: 'build ok')).id;
      await aliceInbox();
      answers.add('[react:👍]\nthanks');
      final before = hub.calls('AcknowledgeMessage').length;
      hub.deliver(
        await alice.messageTo(
          bot.deviceId,
          api.botBundle,
          ReactionPayload(targetId: sentId, emoji: '❤️').encode(),
          extra: {'type': reactionType},
        ),
      );
      await until(() => hub.calls('AcknowledgeMessage').length == before + 1);
      expect(prompts.last, contains(silentReactionHint));
      expect(await aliceInbox(), isEmpty);
    });

    test(
      'reply-mode reaction turns strip the directive and do not react',
      () async {
        await start(reactions: ReactionMode.reply);
        final sentId = (await bot.send(
          to: 'CT-AAAA-0001',
          text: 'build ok',
        )).id;
        await aliceInbox();
        answers.add('[react:👍]\nGlad you like it.');
        final before = hub.calls('AcknowledgeMessage').length;
        hub.deliver(
          await alice.messageTo(
            bot.deviceId,
            api.botBundle,
            ReactionPayload(targetId: sentId, emoji: '❤️').encode(),
            extra: {'type': reactionType},
          ),
        );
        await until(() => hub.calls('AcknowledgeMessage').length == before + 1);
        final inbox = await aliceInbox();
        expect(inbox.single['type'], 'text');
        expect(inbox.single['body'], 'Glad you like it.');
      },
    );

    group('reactFromLocal', () {
      test('defaults to the last message received from the owner', () async {
        final bridge = await start();
        expect(
          await bridge.reactFromLocal('CT-AAAA-0001', null, '👍'),
          SendOutcome.noMessage,
        );
        await say('first');
        final last = await say('second');
        await aliceInbox();
        expect(
          await bridge.reactFromLocal('ct-aaaa-0001', null, '👍'),
          SendOutcome.sent,
        );
        expect(
          reactionOf((await aliceInbox()).single),
          ReactionPayload(targetId: last, emoji: '👍'),
        );
      });

      test('explicit messageId and removal', () async {
        final bridge = await start();
        await say('hi');
        await aliceInbox();
        expect(
          await bridge.reactFromLocal('CT-AAAA-0001', 'some-id', ''),
          SendOutcome.sent,
        );
        expect(
          reactionOf((await aliceInbox()).single),
          const ReactionPayload(targetId: 'some-id', emoji: ''),
        );
      });

      test(
        'group: member -> last group message; foreign -> forbidden',
        () async {
          final bridge = await start();
          final id = await say('look', group: groupId);
          await aliceInbox();
          expect(
            await bridge.reactFromLocal(groupId, null, '✅'),
            SendOutcome.sent,
          );
          final payload = (await aliceInbox()).single;
          expect(payload['groupId'], groupId);
          expect(
            reactionOf(payload),
            ReactionPayload(targetId: id, emoji: '✅'),
          );

          const foreign = '00000000-0000-4000-8000-0000000000c1';
          api.groups[foreign] = [alice.id];
          expect(
            await bridge.reactFromLocal(foreign, 'm', '👍'),
            SendOutcome.forbidden,
          );
        },
      );

      test('non-owners and channels are refused', () async {
        final bridge = await start();
        expect(
          await bridge.reactFromLocal('CT-BBBB-0002', 'm', '👍'),
          SendOutcome.forbidden,
        );
        expect(
          await bridge.reactFromLocal('channel:CH-NEWS-0001', 'm', '👍'),
          SendOutcome.badTarget,
        );
        expect(hub.calls('SendReliableDirectFanout'), isEmpty);
      });
    });
  });
}
