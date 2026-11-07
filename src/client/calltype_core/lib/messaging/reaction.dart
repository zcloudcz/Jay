/// Wire format of a chat reaction (`type: reaction`), shared by the app and
/// the bot runtime (docs/superpowers/specs/2026-11-07-message-reactions.md).
///
/// WHY nothing here throws on input from the wire: a reaction is written by
/// ANOTHER client. An invalid one is dropped (decode returns null), never
/// shown and never retried.
library;

import 'dart:convert';

/// Message payload `type` of a reaction.
const reactionType = 'reaction';

/// Longest accepted emoji in UTF-16 code units. The longest RGI sequences
/// (kiss with two skin tones, subdivision flags) need 15.
const maxReactionEmojiLength = 32;

/// Longest accepted target id (message ids are UUIDs, 36 characters).
const maxReactionTargetLength = 64;

/// The quick bar of the app, in this order.
const quickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

/// One reaction: [emoji] on the message [targetId]; an empty [emoji] removes
/// the sender's reaction.
class ReactionPayload {
  const ReactionPayload({required this.targetId, required this.emoji});

  final String targetId;
  final String emoji;

  bool get removes => emoji.isEmpty;

  /// The `body` string of the payload. Throws [ArgumentError] for values a
  /// receiver would drop, so a bug shows up at the sender.
  String encode() {
    if (!_validTarget(targetId)) {
      throw ArgumentError.value(targetId, 'targetId', 'invalid message id');
    }
    if (emoji.isNotEmpty && !isValidReactionEmoji(emoji)) {
      throw ArgumentError.value(emoji, 'emoji', 'not a single emoji');
    }
    return jsonEncode({'targetId': targetId, 'emoji': emoji});
  }

  /// Parses a received `body`; null when it is not a valid reaction.
  static ReactionPayload? decode(Object? body) {
    if (body is! String || body.length > 1024) return null;
    Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      return null;
    }
    if (json is! Map) return null;
    final targetId = json['targetId'];
    final emoji = json['emoji'];
    if (targetId is! String || !_validTarget(targetId)) return null;
    if (emoji is! String) return null;
    if (emoji.isNotEmpty && !isValidReactionEmoji(emoji)) return null;
    return ReactionPayload(targetId: targetId, emoji: emoji);
  }

  @override
  bool operator ==(Object other) =>
      other is ReactionPayload &&
      other.targetId == targetId &&
      other.emoji == emoji;

  @override
  int get hashCode => Object.hash(targetId, emoji);

  @override
  String toString() => 'ReactionPayload($targetId, $emoji)';
}

bool _validTarget(String id) =>
    id.trim().isNotEmpty && id.length <= maxReactionTargetLength;

final _pictographic = RegExp(r'\p{Extended_Pictographic}', unicode: true);

bool _isPictographic(int rune) =>
    _pictographic.hasMatch(String.fromCharCode(rune));

bool _isRegionalIndicator(int rune) => rune >= 0x1F1E6 && rune <= 0x1F1FF;

bool _isKeycapBase(int rune) =>
    rune == 0x23 || rune == 0x2A || (rune >= 0x30 && rune <= 0x39);

/// Marks that never start a grapheme: variation selectors, skin tones,
/// tag characters (subdivision flags) and the keycap.
bool _isExtender(int rune) =>
    rune == 0xFE0E ||
    rune == 0xFE0F ||
    (rune >= 0x1F3FB && rune <= 0x1F3FF) ||
    (rune >= 0xE0020 && rune <= 0xE007F) ||
    rune == 0x20E3;

/// True when [value] is exactly ONE emoji as a user sees it: a pictographic
/// base with its modifiers or a ZWJ sequence of them, a flag (two regional
/// indicators), or a keycap. No text, no digits alone, no second emoji.
///
/// WHY own code instead of the `characters` package: calltype_core stays
/// dependency-light for the bots, and only emoji graphemes are accepted, which
/// needs far less than full grapheme segmentation.
bool isValidReactionEmoji(String value) {
  if (value.isEmpty || value.length > maxReactionEmojiLength) return false;
  final runes = value.runes.toList();
  var graphemes = 0;
  var afterJoiner = false;
  var regionalRun = 0;
  var emoji = false;
  var pendingKeycap = false;
  for (var i = 0; i < runes.length; i++) {
    final rune = runes[i];
    if (rune == 0x200D) {
      // A joiner glues two pictographs; never first, never doubled.
      if (i == 0 || afterJoiner) return false;
      afterJoiner = true;
      regionalRun = 0;
      continue;
    }
    if (_isExtender(rune)) {
      if (i == 0) return false;
      if (rune == 0x20E3) {
        if (!pendingKeycap) return false;
        pendingKeycap = false;
        emoji = true;
      }
      continue;
    }
    if (_isRegionalIndicator(rune)) {
      // Pairs form one flag; the second of a pair does not start a grapheme.
      if (regionalRun.isOdd) {
        regionalRun++;
        continue;
      }
      regionalRun++;
    } else {
      regionalRun = 0;
      if (_isKeycapBase(rune)) {
        pendingKeycap = true;
      } else if (!_isPictographic(rune)) {
        return false;
      }
    }
    if (!afterJoiner) graphemes++;
    afterJoiner = false;
    if (!pendingKeycap) emoji = true;
  }
  return graphemes == 1 &&
      emoji &&
      !afterJoiner &&
      !pendingKeycap &&
      regionalRun != 1;
}
