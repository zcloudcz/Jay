/// Wire format of "this chat was deleted" between the devices of ONE
/// identity (`type: chat-deleted`), shared by the app and tests
/// (docs/superpowers/specs/2026-11-09-delete-chats-contacts.md, D2).
///
/// WHY decoding never throws: the body comes from another device. An invalid
/// message decodes to null (the receiver acks and drops it).
library;

import 'dart:convert';

/// Message payload `type` of a chat deletion sync.
const chatDeletedType = 'chat-deleted';

/// Longest accepted conversation id (device and group ids are UUIDs, 36
/// characters).
const maxChatDeletedConversationLength = 64;

/// Largest accepted `deletedAt`: the largest integer a JSON number keeps
/// exactly in JavaScript (the web build decodes JSON there).
const maxDeletedAt = 9007199254740991;

/// "This identity deleted [conversationId] at [deletedAt]" (ms since
/// epoch). A receiver deletes only the messages created up to that moment,
/// so a message that arrived later is never lost.
class ChatDeletedPayload {
  const ChatDeletedPayload({
    required this.conversationId,
    required this.deletedAt,
  });

  final String conversationId;
  final int deletedAt;

  /// The `body` string of the payload. Throws [ArgumentError] for values a
  /// receiver would drop, so a bug shows up at the sender.
  String encode() {
    if (!_validConversation(conversationId)) {
      throw ArgumentError.value(
        conversationId,
        'conversationId',
        'invalid conversation id',
      );
    }
    if (!_validDeletedAt(deletedAt)) {
      throw ArgumentError.value(
        deletedAt,
        'deletedAt',
        'not a positive ms value',
      );
    }
    return jsonEncode({
      'v': 1,
      'conversationId': conversationId,
      'deletedAt': deletedAt,
    });
  }

  /// Parses a received `body`; null when it is not a valid deletion (or a
  /// newer version this client does not know).
  static ChatDeletedPayload? decode(Object? body) {
    if (body is! String || body.length > 1024) return null;
    Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      return null;
    }
    if (json is! Map || json['v'] != 1) return null;
    final conversationId = json['conversationId'];
    final deletedAt = json['deletedAt'];
    if (conversationId is! String || !_validConversation(conversationId)) {
      return null;
    }
    if (deletedAt is! int || !_validDeletedAt(deletedAt)) return null;
    return ChatDeletedPayload(
      conversationId: conversationId,
      deletedAt: deletedAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ChatDeletedPayload &&
      other.conversationId == conversationId &&
      other.deletedAt == deletedAt;

  @override
  int get hashCode => Object.hash(conversationId, deletedAt);

  @override
  String toString() => 'ChatDeletedPayload($conversationId, $deletedAt)';
}

bool _validConversation(String id) =>
    id.trim().isNotEmpty &&
    id.trim() == id &&
    id.length <= maxChatDeletedConversationLength;

bool _validDeletedAt(int value) => value > 0 && value <= maxDeletedAt;
