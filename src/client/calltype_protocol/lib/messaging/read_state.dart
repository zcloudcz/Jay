/// Wire format of read-state sync between the devices of ONE identity
/// (`type: read-state`), shared by the app and tests
/// (docs/superpowers/specs/2026-11-09-auto-resend-read-sync.md, part 2).
///
/// WHY decoding never throws: the body comes from another device. An invalid
/// message decodes to null (the receiver acks and drops it).
library;

import 'dart:convert';

/// Message payload `type` of a read-state sync.
const readStateType = 'read-state';

/// Longest accepted conversation id (device and group ids are UUIDs, 36
/// characters).
const maxReadStateConversationLength = 64;

/// Largest accepted `readUpTo`: the largest integer a JSON number keeps
/// exactly in JavaScript (the web build decodes JSON there).
const maxReadUpTo = 9007199254740991;

/// "This identity has read [conversationId] up to [readUpTo]": the
/// `createdAt` in ms since epoch of the newest incoming message seen there.
class ReadStatePayload {
  const ReadStatePayload({
    required this.conversationId,
    required this.readUpTo,
  });

  final String conversationId;
  final int readUpTo;

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
    if (!_validReadUpTo(readUpTo)) {
      throw ArgumentError.value(
        readUpTo,
        'readUpTo',
        'not a positive ms value',
      );
    }
    return jsonEncode({
      'v': 1,
      'conversationId': conversationId,
      'readUpTo': readUpTo,
    });
  }

  /// Parses a received `body`; null when it is not a valid read state (or
  /// a newer version this client does not know).
  static ReadStatePayload? decode(Object? body) {
    if (body is! String || body.length > 1024) return null;
    Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      return null;
    }
    if (json is! Map || json['v'] != 1) return null;
    final conversationId = json['conversationId'];
    final readUpTo = json['readUpTo'];
    if (conversationId is! String || !_validConversation(conversationId)) {
      return null;
    }
    if (readUpTo is! int || !_validReadUpTo(readUpTo)) return null;
    return ReadStatePayload(conversationId: conversationId, readUpTo: readUpTo);
  }

  @override
  bool operator ==(Object other) =>
      other is ReadStatePayload &&
      other.conversationId == conversationId &&
      other.readUpTo == readUpTo;

  @override
  int get hashCode => Object.hash(conversationId, readUpTo);

  @override
  String toString() => 'ReadStatePayload($conversationId, $readUpTo)';
}

bool _validConversation(String id) =>
    id.trim().isNotEmpty &&
    id.trim() == id &&
    id.length <= maxReadStateConversationLength;

bool _validReadUpTo(int value) => value > 0 && value <= maxReadUpTo;
