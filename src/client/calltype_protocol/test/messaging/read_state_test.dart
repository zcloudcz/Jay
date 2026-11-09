import 'dart:convert';

import 'package:calltype_protocol/messaging/read_state.dart';
import 'package:test/test.dart';

void main() {
  const id = 'b0000000-0000-4000-8000-000000000001';

  test('round trip', () {
    const payload = ReadStatePayload(
      conversationId: id,
      readUpTo: 1762682400123,
    );
    final body = payload.encode();
    expect(jsonDecode(body), {
      'v': 1,
      'conversationId': id,
      'readUpTo': 1762682400123,
    });
    expect(ReadStatePayload.decode(body), payload);
  });

  test('encode refuses what a receiver would drop', () {
    for (final bad in [
      const ReadStatePayload(conversationId: '', readUpTo: 1),
      const ReadStatePayload(conversationId: ' x', readUpTo: 1),
      ReadStatePayload(conversationId: 'x' * 65, readUpTo: 1),
      const ReadStatePayload(conversationId: id, readUpTo: 0),
      const ReadStatePayload(conversationId: id, readUpTo: -5),
      const ReadStatePayload(conversationId: id, readUpTo: maxReadUpTo + 1),
    ]) {
      expect(bad.encode, throwsArgumentError, reason: '$bad');
    }
  });

  test('decode returns null for invalid input and never throws', () {
    for (final body in <Object?>[
      null,
      42,
      '',
      'not json',
      '[]',
      '{}',
      jsonEncode({'v': 2, 'conversationId': id, 'readUpTo': 5}),
      jsonEncode({'conversationId': id, 'readUpTo': 5}),
      jsonEncode({'v': 1, 'conversationId': 7, 'readUpTo': 5}),
      jsonEncode({'v': 1, 'conversationId': '', 'readUpTo': 5}),
      jsonEncode({'v': 1, 'conversationId': id, 'readUpTo': '5'}),
      jsonEncode({'v': 1, 'conversationId': id, 'readUpTo': 5.5}),
      jsonEncode({'v': 1, 'conversationId': id, 'readUpTo': 0}),
      jsonEncode({'v': 1, 'conversationId': id}),
      jsonEncode({'v': 1, 'conversationId': 'x' * 65, 'readUpTo': 5}),
      '{"v":1,"conversationId":"$id","readUpTo":5,"pad":"${'x' * 1100}"}',
    ]) {
      expect(ReadStatePayload.decode(body), isNull, reason: '$body');
    }
  });

  test('unknown extra keys are ignored', () {
    expect(
      ReadStatePayload.decode(
        jsonEncode({'v': 1, 'conversationId': id, 'readUpTo': 5, 'x': true}),
      ),
      const ReadStatePayload(conversationId: id, readUpTo: 5),
    );
  });
}
