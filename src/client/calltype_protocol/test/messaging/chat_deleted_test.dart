import 'dart:convert';

import 'package:calltype_protocol/messaging/chat_deleted.dart';
import 'package:test/test.dart';

void main() {
  const id = 'b0000000-0000-4000-8000-000000000001';

  test('round trip', () {
    const payload = ChatDeletedPayload(
      conversationId: id,
      deletedAt: 1762682400123,
    );
    final body = payload.encode();
    expect(jsonDecode(body), {
      'v': 1,
      'conversationId': id,
      'deletedAt': 1762682400123,
    });
    expect(ChatDeletedPayload.decode(body), payload);
  });

  test('encode refuses what a receiver would drop', () {
    for (final bad in [
      const ChatDeletedPayload(conversationId: '', deletedAt: 1),
      const ChatDeletedPayload(conversationId: ' x', deletedAt: 1),
      ChatDeletedPayload(conversationId: 'x' * 65, deletedAt: 1),
      const ChatDeletedPayload(conversationId: id, deletedAt: 0),
      const ChatDeletedPayload(conversationId: id, deletedAt: -5),
      const ChatDeletedPayload(conversationId: id, deletedAt: maxDeletedAt + 1),
    ]) {
      expect(bad.encode, throwsArgumentError, reason: '$bad');
    }
  });

  test('a 64 character id and the largest ms value are accepted', () {
    final payload = ChatDeletedPayload(
      conversationId: 'x' * 64,
      deletedAt: maxDeletedAt,
    );
    expect(ChatDeletedPayload.decode(payload.encode()), payload);
  });

  test('decode returns null for invalid input and never throws', () {
    for (final body in <Object?>[
      null,
      42,
      '',
      'not json',
      '[]',
      '{}',
      jsonEncode({'v': 2, 'conversationId': id, 'deletedAt': 5}),
      jsonEncode({'conversationId': id, 'deletedAt': 5}),
      jsonEncode({'v': 1, 'conversationId': 7, 'deletedAt': 5}),
      jsonEncode({'v': 1, 'conversationId': '', 'deletedAt': 5}),
      jsonEncode({'v': 1, 'conversationId': ' $id', 'deletedAt': 5}),
      jsonEncode({'v': 1, 'conversationId': id, 'deletedAt': '5'}),
      jsonEncode({'v': 1, 'conversationId': id, 'deletedAt': 5.5}),
      jsonEncode({'v': 1, 'conversationId': id, 'deletedAt': 0}),
      jsonEncode({'v': 1, 'conversationId': id}),
      jsonEncode({'v': 1, 'conversationId': 'x' * 65, 'deletedAt': 5}),
      '{"v":1,"conversationId":"$id","deletedAt":5,"pad":"${'x' * 1100}"}',
    ]) {
      expect(ChatDeletedPayload.decode(body), isNull, reason: '$body');
    }
  });

  test('unknown extra keys are ignored', () {
    expect(
      ChatDeletedPayload.decode(
        jsonEncode({'v': 1, 'conversationId': id, 'deletedAt': 5, 'x': true}),
      ),
      const ChatDeletedPayload(conversationId: id, deletedAt: 5),
    );
  });
}
