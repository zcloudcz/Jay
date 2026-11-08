import 'package:drift/drift.dart';

import 'package:calltype_core/storage/database.dart';

export 'package:calltype_core/messaging/reaction.dart';

/// Message types a reaction may target: real chat bubbles (a poll too). A
/// call log line, a device notice or a control row is not something to
/// react to.
const reactableTypes = {
  'text',
  'file',
  'media',
  'image',
  'audio',
  'video',
  'poll',
};

/// Stores [emoji] (or a removal, '') as the reaction of [reactorId] on
/// [messageId] if it is newer than (or as new as) the stored one: last
/// writer wins per (message, reactor). Returns whether it was applied.
///
/// WHY a tie is applied: the same reactor's reactions come over one ordered
/// ratchet per device, so within one millisecond the arrival order is the
/// sending order. Callers that need atomicity wrap it in their transaction.
Future<bool> applyReaction(
  AppDatabase db, {
  required String messageId,
  required String reactorId,
  required String conversationId,
  required String emoji,
  required int reactedAt,
}) async {
  final current =
      await (db.select(db.messageReactions)..where(
            (r) =>
                r.messageId.equals(messageId) & r.reactorId.equals(reactorId),
          ))
          .getSingleOrNull();
  if (current != null) {
    // Never moved into another conversation by a later claim.
    if (current.conversationId != conversationId) return false;
    if (reactedAt < current.reactedAt) return false;
  }
  await db
      .into(db.messageReactions)
      .insertOnConflictUpdate(
        MessageReactionsCompanion.insert(
          messageId: messageId,
          reactorId: reactorId,
          conversationId: conversationId,
          emoji: emoji,
          reactedAt: reactedAt,
        ),
      );
  return true;
}

/// The reaction row of [reactorId] on [messageId], or null.
Future<MessageReaction?> reactionOf(
  AppDatabase db,
  String messageId,
  String reactorId,
) =>
    (db.select(db.messageReactions)..where(
          (r) => r.messageId.equals(messageId) & r.reactorId.equals(reactorId),
        ))
        .getSingleOrNull();

/// Removes every reaction on [messageId] (its target was deleted).
Future<void> deleteReactionsOf(AppDatabase db, String messageId) => (db.delete(
  db.messageReactions,
)..where((r) => r.messageId.equals(messageId))).go();

/// One chip under a bubble: [emoji] with everyone who picked it.
class ReactionSummary {
  const ReactionSummary({
    required this.emoji,
    required this.reactorIds,
    required this.mine,
  });

  final String emoji;

  /// Identity ids, oldest reaction first.
  final List<String> reactorIds;

  /// The local user is one of [reactorIds].
  final bool mine;

  int get count => reactorIds.length;

  @override
  bool operator ==(Object other) =>
      other is ReactionSummary &&
      other.emoji == emoji &&
      other.mine == mine &&
      _sameList(other.reactorIds, reactorIds);

  @override
  int get hashCode => Object.hash(emoji, mine, Object.hashAll(reactorIds));

  @override
  String toString() => 'ReactionSummary($emoji x$count${mine ? ', mine' : ''})';
}

bool _sameList(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Groups the rows of ONE message into chips: removals are skipped, the
/// emoji picked first comes first, each chip lists its reactors oldest
/// first.
List<ReactionSummary> summarizeReactions(
  Iterable<MessageReaction> rows, {
  required String myId,
}) {
  final sorted = rows.where((r) => r.emoji.isNotEmpty).toList()
    ..sort((a, b) => a.reactedAt.compareTo(b.reactedAt));
  final byEmoji = <String, List<String>>{};
  for (final row in sorted) {
    (byEmoji[row.emoji] ??= []).add(row.reactorId);
  }
  final me = myId.toLowerCase();
  return [
    for (final MapEntry(key: emoji, value: ids) in byEmoji.entries)
      ReactionSummary(
        emoji: emoji,
        reactorIds: ids,
        mine: ids.any((id) => id.toLowerCase() == me),
      ),
  ];
}

/// A reaction the inbox just applied (for the local notification).
class AppliedReaction {
  const AppliedReaction({
    required this.conversationId,
    required this.reactorId,
    required this.emoji,
    required this.target,
  });

  final String conversationId;
  final String reactorId;

  /// '' when the reaction was removed.
  final String emoji;

  /// The reacted-to message; null when it has not arrived (yet).
  final Message? target;
}
