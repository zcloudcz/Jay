import 'dart:convert';

import 'package:calltype_protocol/messaging/group_topic.dart';
import 'package:test/test.dart';

void main() {
  group('GroupTopicPayload', () {
    test('round trips and trims', () {
      final body = const GroupTopicPayload(
        topic: '  Plan the trip  ',
        version: 1763031330123,
      ).encode();
      expect(jsonDecode(body), {
        'topic': 'Plan the trip',
        'version': 1763031330123,
      });
      expect(
        GroupTopicPayload.decode(body),
        const GroupTopicPayload(topic: 'Plan the trip', version: 1763031330123),
      );
    });

    test('empty topic clears', () {
      final body = const GroupTopicPayload(topic: '', version: 5).encode();
      expect(GroupTopicPayload.decode(body)?.topic, '');
    });

    test('length limit is 4000 characters', () {
      final max = 'é' * maxGroupTopicLength;
      final ok = GroupTopicPayload(topic: max, version: 1).encode();
      expect(GroupTopicPayload.decode(ok)?.topic, max);
      expect(
        () => GroupTopicPayload(topic: '${max}x', version: 1).encode(),
        throwsArgumentError,
      );
      expect(
        GroupTopicPayload.decode(
          jsonEncode({'topic': '${max}x', 'version': 1}),
        ),
        isNull,
      );
    });

    test('encode refuses a non-positive version', () {
      expect(
        () => const GroupTopicPayload(topic: 'a', version: 0).encode(),
        throwsArgumentError,
      );
    });

    test('decode drops invalid input without throwing', () {
      for (final body in <Object?>[
        null,
        42,
        '',
        'not json',
        '[]',
        '{}',
        jsonEncode({'topic': 'a'}),
        jsonEncode({'version': 1}),
        jsonEncode({'topic': 1, 'version': 1}),
        jsonEncode({'topic': 'a', 'version': '1'}),
        jsonEncode({'topic': 'a', 'version': 1.5}),
        jsonEncode({'topic': 'a', 'version': 0}),
        jsonEncode({'topic': 'a', 'version': -3}),
        'x' * (17 * 1024),
      ]) {
        expect(GroupTopicPayload.decode(body), isNull, reason: '$body');
      }
    });
  });
}
