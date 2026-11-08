import 'dart:convert';

import 'package:calltype_protocol/messaging/reaction.dart';
import 'package:test/test.dart';

void main() {
  group('isValidReactionEmoji', () {
    test('accepts single emoji graphemes', () {
      for (final emoji in [
        ...quickReactions,
        '🎉',
        '👍🏽', // skin tone
        '👨‍👩‍👧', // ZWJ family
        '🏳️‍🌈', // VS16 + ZWJ
        '🇨🇿', // flag
        '🏴󠁧󠁢󠁥󠁮󠁧󠁿', // subdivision flag (tags)
        '1️⃣', // keycap
        '#️⃣',
        '👩🏻‍❤️‍💋‍👨🏼', // longest RGI kind
      ]) {
        expect(isValidReactionEmoji(emoji), isTrue, reason: emoji);
      }
    });

    test('refuses text, several emojis and broken sequences', () {
      for (final value in [
        '',
        'a',
        'ok',
        '1',
        ' 👍',
        '👍 ',
        '👍👍',
        '👍a',
        '🇨', // half a flag
        '🇨🇿🇸', // flag and a half
        '\u200D👍', // leading joiner
        '👍\u200D', // trailing joiner
        '\uFE0F', // lone selector
        '\u{1F3FB}', // lone skin tone
        '<script>',
        '👍' * 20,
      ]) {
        expect(isValidReactionEmoji(value), isFalse, reason: value);
      }
    });
  });

  group('ReactionPayload', () {
    test('encode/decode round trip, also for a removal', () {
      for (final payload in [
        const ReactionPayload(targetId: 'm-1', emoji: '👍'),
        const ReactionPayload(targetId: 'm-1', emoji: ''),
      ]) {
        final body = payload.encode();
        expect(jsonDecode(body), {
          'targetId': payload.targetId,
          'emoji': payload.emoji,
        });
        expect(ReactionPayload.decode(body), payload);
      }
      expect(const ReactionPayload(targetId: 'm', emoji: '').removes, isTrue);
    });

    test('encode refuses what a receiver would drop', () {
      expect(
        () => const ReactionPayload(targetId: 'm', emoji: 'ok').encode(),
        throwsArgumentError,
      );
      expect(
        () => const ReactionPayload(targetId: ' ', emoji: '👍').encode(),
        throwsArgumentError,
      );
    });

    test('decode drops anything malformed', () {
      for (final body in [
        null,
        42,
        'not json',
        '[]',
        '{}',
        '{"targetId": "m"}',
        '{"emoji": "👍"}',
        '{"targetId": 1, "emoji": "👍"}',
        '{"targetId": "m", "emoji": 1}',
        '{"targetId": "", "emoji": "👍"}',
        '{"targetId": "m", "emoji": "hello"}',
        jsonEncode({'targetId': 'x' * 65, 'emoji': '👍'}),
        jsonEncode({'targetId': 'm', 'emoji': '👍', 'pad': 'x' * 2000}),
      ]) {
        expect(ReactionPayload.decode(body), isNull, reason: '$body');
      }
    });

    test('decode ignores unknown keys', () {
      expect(
        ReactionPayload.decode('{"targetId":"m","emoji":"❤️","x":true}'),
        const ReactionPayload(targetId: 'm', emoji: '❤️'),
      );
    });
  });
}
