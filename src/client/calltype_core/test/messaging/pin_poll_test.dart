import 'dart:convert';

import 'package:calltype_core/messaging/pin.dart';
import 'package:calltype_core/messaging/poll.dart';
import 'package:test/test.dart';

void main() {
  group('PinPayload', () {
    test('round-trips pin and unpin', () {
      for (final pinned in [true, false]) {
        final payload = PinPayload(targetId: 'm1', pinned: pinned);
        expect(PinPayload.decode(payload.encode()), payload);
      }
    });

    test('drops invalid bodies', () {
      for (final body in [
        null,
        42,
        'not json',
        '[]',
        jsonEncode({'targetId': 'm1'}),
        jsonEncode({'targetId': 'm1', 'pinned': 'yes'}),
        jsonEncode({'targetId': '', 'pinned': true}),
        jsonEncode({'targetId': '  ', 'pinned': true}),
        jsonEncode({'targetId': 'x' * 65, 'pinned': true}),
        jsonEncode({'targetId': 7, 'pinned': true}),
        'x' * 2000,
      ]) {
        expect(PinPayload.decode(body), isNull, reason: '$body');
      }
    });

    test('refuses to encode an invalid target', () {
      expect(
        () => const PinPayload(targetId: '', pinned: true).encode(),
        throwsArgumentError,
      );
    });
  });

  group('PollPayload', () {
    test('create trims and round-trips through the wire object', () {
      final poll = PollPayload.create(
        question: '  Lunch? ',
        options: [' Pizza', 'Sushi '],
        multiple: true,
      );
      expect(poll.question, 'Lunch?');
      expect(poll.options, ['Pizza', 'Sushi']);
      expect(PollPayload.tryParse(poll.toJson()), poll);
      expect(PollPayload.tryDecode(poll.encode()), poll);
      expect(jsonDecode(poll.encode()), {
        'v': 1,
        'question': 'Lunch?',
        'options': ['Pizza', 'Sushi'],
        'multiple': true,
      });
    });

    test('limits: question, option count, option length, duplicates', () {
      expect(PollPayload.problemOf('', ['a', 'b']), 'question');
      expect(PollPayload.problemOf('q' * 301, ['a', 'b']), 'question');
      expect(PollPayload.problemOf('q', ['a']), 'options');
      expect(
        PollPayload.problemOf('q', [for (var i = 0; i < 11; i++) '$i']),
        'options',
      );
      expect(PollPayload.problemOf('q', ['a', ' ']), 'option');
      expect(PollPayload.problemOf('q', ['a', 'o' * 101]), 'option');
      expect(PollPayload.problemOf('q', ['a', ' a']), 'duplicate');
      expect(
        PollPayload.problemOf('q' * 300, [for (var i = 0; i < 10; i++) '$i']),
        isNull,
      );
      expect(
        () => PollPayload.create(question: '', options: ['a', 'b']),
        throwsArgumentError,
      );
    });

    test('tryParse ignores anything malformed', () {
      final good = {
        'v': 1,
        'question': 'Q',
        'options': ['a', 'b'],
        'multiple': false,
      };
      expect(PollPayload.tryParse(good), isNotNull);
      for (final bad in [
        null,
        'Q',
        {...good, 'v': 2},
        {...good, 'question': 5},
        {...good, 'question': ' Q'},
        {...good, 'options': 'a,b'},
        {
          ...good,
          'options': ['a', 1],
        },
        {
          ...good,
          'options': ['a'],
        },
        {
          ...good,
          'options': ['a', 'a'],
        },
        {
          ...good,
          'options': ['a ', 'b'],
        },
        {...good, 'multiple': 'no'},
        {...good}..remove('multiple'),
      ]) {
        expect(PollPayload.tryParse(bad), isNull, reason: '$bad');
      }
      expect(PollPayload.tryDecode('not json'), isNull);
      expect(PollPayload.tryDecode(null), isNull);
    });

    test('fallback text lists the question and the options', () {
      final poll = PollPayload.create(question: 'Lunch?', options: ['A', 'B']);
      expect(
        poll.fallbackText('Update to vote.'),
        '📊 Lunch?\n• A\n• B\nUpdate to vote.',
      );
    });
  });

  group('PollVotePayload', () {
    test('sorts, dedupes and round-trips; empty withdraws', () {
      final vote = PollVotePayload(pollId: 'p', options: [2, 0, 2]);
      expect(vote.options, [0, 2]);
      expect(PollVotePayload.decode(vote.encode()), vote);
      final none = PollVotePayload(pollId: 'p', options: const []);
      expect(none.withdraws, isTrue);
      expect(PollVotePayload.decode(none.encode())!.withdraws, isTrue);
    });

    test('drops invalid bodies', () {
      for (final body in [
        null,
        'x',
        jsonEncode({'pollId': 'p'}),
        jsonEncode({
          'pollId': 'p',
          'options': [10],
        }),
        jsonEncode({
          'pollId': 'p',
          'options': [-1],
        }),
        jsonEncode({
          'pollId': 'p',
          'options': [1, 1],
        }),
        jsonEncode({
          'pollId': 'p',
          'options': ['1'],
        }),
        jsonEncode({
          'pollId': '',
          'options': [1],
        }),
        jsonEncode({
          'pollId': 'x' * 65,
          'options': [1],
        }),
      ]) {
        expect(PollVotePayload.decode(body), isNull, reason: '$body');
      }
      expect(
        () => PollVotePayload(pollId: 'p', options: [11]).encode(),
        throwsArgumentError,
      );
    });

    test('voteFits checks indexes and single choice against the poll', () {
      final single = PollPayload.create(question: 'Q', options: ['a', 'b']);
      final multi = PollPayload.create(
        question: 'Q',
        options: ['a', 'b', 'c'],
        multiple: true,
      );
      expect(voteFits(single, [1]), isTrue);
      expect(voteFits(single, []), isTrue);
      expect(voteFits(single, [0, 1]), isFalse);
      expect(voteFits(single, [2]), isFalse);
      expect(voteFits(multi, [0, 2]), isTrue);
      expect(decodeVoteOptions('[0,2]'), [0, 2]);
      expect(decodeVoteOptions('garbage'), isEmpty);
      expect(decodeVoteOptions('["a"]'), isEmpty);
    });
  });
}
