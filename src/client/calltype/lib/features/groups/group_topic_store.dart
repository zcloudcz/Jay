import 'dart:convert';

import 'package:calltype_core/messaging/group_topic.dart';
import 'package:calltype_core/storage/database.dart';

/// Local storage of group topics (spec 2026-11-13-group-topics row 17).
///
/// WHY the `backup_state` key-value table and not a column: no drift
/// `schemaVersion` bump, so this cannot collide with other unmerged branches
/// that change the schema (skill rule for local per-conversation state).
const groupTopicKeyPrefix = 'group-topic:';

String groupTopicKey(String conversationId) =>
    '$groupTopicKeyPrefix$conversationId';

/// The topic this device knows for one group.
class StoredGroupTopic {
  const StoredGroupTopic({
    required this.topic,
    required this.version,
    required this.setBy,
  });

  /// Trimmed, 0..[maxGroupTopicLength] characters; empty = cleared.
  final String topic;

  /// The server-recorded version it was accepted at (receiver rule 4).
  final int version;

  /// Identity id of the admin who set it (the authenticated sender).
  final String setBy;

  String encode() =>
      jsonEncode({'topic': topic, 'version': version, 'setBy': setBy});

  /// Null for anything malformed: a damaged row reads as "no topic" instead
  /// of breaking the chat header, the inbox or a restore.
  static StoredGroupTopic? parse(String? value) {
    if (value == null) return null;
    Object? json;
    try {
      json = jsonDecode(value);
    } on FormatException {
      return null;
    }
    return fromJson(json);
  }

  /// Same validation for a stored row and a backup entry.
  static StoredGroupTopic? fromJson(Object? json) {
    if (json is! Map) return null;
    final topic = json['topic'];
    final version = json['version'];
    final setBy = json['setBy'];
    if (topic is! String ||
        topic.length > maxGroupTopicLength ||
        version is! int ||
        version <= 0 ||
        setBy is! String ||
        setBy.isEmpty) {
      return null;
    }
    return StoredGroupTopic(
      topic: topic.trim(),
      version: version,
      setBy: setBy,
    );
  }

  Map<String, Object> toJson() => {
    'topic': topic,
    'version': version,
    'setBy': setBy,
  };
}

Future<StoredGroupTopic?> readGroupTopic(
  AppDatabase db,
  String conversationId,
) async {
  final row =
      await (db.select(db.backupState)
            ..where((s) => s.key.equals(groupTopicKey(conversationId))))
          .getSingleOrNull();
  return StoredGroupTopic.parse(row?.value);
}

/// Emits the stored topic of [conversationId] now and after every change
/// (drift watch), so an open chat header or Group info updates by itself
/// when the inbox applies a new topic.
Stream<StoredGroupTopic?> watchGroupTopic(
  AppDatabase db,
  String conversationId,
) =>
    (db.select(db.backupState)
          ..where((s) => s.key.equals(groupTopicKey(conversationId))))
        .watchSingleOrNull()
        .map((row) => StoredGroupTopic.parse(row?.value));

/// Stores [topic] when its version is newer than the stored one (receiver
/// rule 4: last writer wins by server version, an equal version is an
/// idempotent no-op). Returns whether it was written. A malformed stored
/// value counts as none and is replaced.
Future<bool> writeGroupTopicIfNewer(
  AppDatabase db,
  String conversationId,
  StoredGroupTopic topic,
) async {
  final current = await readGroupTopic(db, conversationId);
  if (current != null && current.version >= topic.version) return false;
  await db
      .into(db.backupState)
      .insertOnConflictUpdate(
        BackupStateCompanion.insert(
          key: groupTopicKey(conversationId),
          value: topic.encode(),
        ),
      );
  return true;
}
