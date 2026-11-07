/// Wire format of a pinned message (`type: pin`), shared by the app and the
/// bot runtime (docs/superpowers/specs/2026-11-08-chat-extras.md).
///
/// WHY nothing here throws on input from the wire: a pin is written by
/// ANOTHER client. An invalid one is dropped (decode returns null), never
/// shown and never retried.
library;

import 'dart:convert';

/// Message payload `type` of a pin or unpin.
const pinType = 'pin';

/// Most pinned messages a conversation shows (WhatsApp: 3).
const maxPinsPerConversation = 3;

/// Longest accepted target id (message ids are UUIDs, 36 characters).
const maxPinTargetLength = 64;

/// Pins ([pinned] true) or unpins the message [targetId].
class PinPayload {
  const PinPayload({required this.targetId, required this.pinned});

  final String targetId;
  final bool pinned;

  /// The `body` string of the payload. Throws [ArgumentError] for a value a
  /// receiver would drop, so a bug shows up at the sender.
  String encode() {
    if (!_validTarget(targetId)) {
      throw ArgumentError.value(targetId, 'targetId', 'invalid message id');
    }
    return jsonEncode({'targetId': targetId, 'pinned': pinned});
  }

  /// Parses a received `body`; null when it is not a valid pin.
  static PinPayload? decode(Object? body) {
    if (body is! String || body.length > 1024) return null;
    Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      return null;
    }
    if (json is! Map) return null;
    final targetId = json['targetId'];
    final pinned = json['pinned'];
    if (targetId is! String || !_validTarget(targetId)) return null;
    if (pinned is! bool) return null;
    return PinPayload(targetId: targetId, pinned: pinned);
  }

  @override
  bool operator ==(Object other) =>
      other is PinPayload &&
      other.targetId == targetId &&
      other.pinned == pinned;

  @override
  int get hashCode => Object.hash(targetId, pinned);

  @override
  String toString() => 'PinPayload($targetId, pinned: $pinned)';
}

bool _validTarget(String id) =>
    id.trim().isNotEmpty && id.length <= maxPinTargetLength;
