/// Wire format of a group topic (`type: group-topic`), shared by the app and
/// the bot runtime (docs/superpowers/specs/2026-11-13-group-topics.md).
///
/// WHY nothing here throws on input from the wire: a topic is written by
/// ANOTHER client. An invalid one is dropped (decode returns null), never
/// shown and never retried.
library;

import 'dart:convert';

/// Message payload `type` of a group topic change (a control message).
const groupTopicType = 'group-topic';

/// Longest topic in characters (Dart `String.length`, after trimming).
const maxGroupTopicLength = 4000;

/// Longest accepted `body` string. A 4000 character topic of non-ASCII text
/// JSON-escaped stays well below this; anything larger is not ours.
const _maxBodyLength = 16 * 1024;

/// Sets the topic of a group to [topic] (empty = no topic) at [version].
///
/// [version] is the one the server recorded for this change
/// (`PUT /groups/{id}/topic`); receivers accept the content only when the
/// server's current record names this version and this sender.
class GroupTopicPayload {
  const GroupTopicPayload({required this.topic, required this.version});

  /// The topic text, already trimmed by [decode]; may be empty (cleared).
  final String topic;

  /// Server-assigned, strictly increasing per group (Unix ms based).
  final int version;

  /// The `body` string of the payload. Trims [topic]. Throws
  /// [ArgumentError] for a value a receiver would drop, so a bug shows up at
  /// the sender.
  String encode() {
    final text = topic.trim();
    if (text.length > maxGroupTopicLength) {
      throw ArgumentError.value(
        text.length,
        'topic',
        'longer than $maxGroupTopicLength characters',
      );
    }
    if (version <= 0) {
      throw ArgumentError.value(version, 'version', 'must be positive');
    }
    return jsonEncode({'topic': text, 'version': version});
  }

  /// Parses a received `body`; null when it is not a valid topic.
  static GroupTopicPayload? decode(Object? body) {
    if (body is! String || body.length > _maxBodyLength) return null;
    Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      return null;
    }
    if (json is! Map) return null;
    final topic = json['topic'];
    final version = json['version'];
    if (topic is! String) return null;
    // A JSON number with a fraction (1.5) or a huge double is not a version.
    if (version is! int || version <= 0) return null;
    final text = topic.trim();
    if (text.length > maxGroupTopicLength) return null;
    return GroupTopicPayload(topic: text, version: version);
  }

  @override
  bool operator ==(Object other) =>
      other is GroupTopicPayload &&
      other.topic == topic &&
      other.version == version;

  @override
  int get hashCode => Object.hash(topic, version);

  @override
  String toString() =>
      'GroupTopicPayload(v$version, ${topic.length} characters)';
}
