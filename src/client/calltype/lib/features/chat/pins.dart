import 'package:calltype_core/messaging/pin.dart';
import 'package:drift/drift.dart';

import 'package:calltype_core/storage/database.dart';
import 'reactions.dart' show reactableTypes;

export 'package:calltype_core/messaging/pin.dart';

/// Message types that may be pinned: real chat bubbles, polls included.
const pinnableTypes = {...reactableTypes};

/// Stores the pin state of [messageId] in [conversationId] if it is newer
/// than (or as new as) the stored one: last writer wins per (conversation,
/// message), spec 2026-11-08-chat-extras. Returns whether it was applied.
///
/// WHY a tie is applied: one sender's control messages come over one ordered
/// ratchet per device, so within one millisecond arrival order is sending
/// order. Callers that need atomicity wrap it in their transaction.
Future<bool> applyPin(
  AppDatabase db, {
  required String conversationId,
  required String messageId,
  required bool pinned,
  required String pinnedBy,
  required int changedAt,
}) async {
  final current = await pinOf(db, conversationId, messageId);
  if (current != null && changedAt < current.changedAt) return false;
  await db
      .into(db.messagePins)
      .insertOnConflictUpdate(
        MessagePinsCompanion.insert(
          conversationId: conversationId,
          messageId: messageId,
          pinned: pinned,
          pinnedBy: pinnedBy,
          changedAt: changedAt,
        ),
      );
  return true;
}

/// The pin row of [messageId] in [conversationId], or null.
Future<MessagePin?> pinOf(
  AppDatabase db,
  String conversationId,
  String messageId,
) =>
    (db.select(db.messagePins)..where(
          (p) =>
              p.conversationId.equals(conversationId) &
              p.messageId.equals(messageId),
        ))
        .getSingleOrNull();

/// Removes every pin of [messageId] (it was deleted).
Future<void> deletePinsOf(AppDatabase db, String messageId) => (db.delete(
  db.messagePins,
)..where((p) => p.messageId.equals(messageId))).go();

/// The pinned messages a conversation shows, newest pin first, at most
/// [maxPinsPerConversation]: only active pins whose message exists in that
/// conversation and is not a tombstone. [messagesById] holds the
/// conversation's messages.
List<Message> visiblePins(
  Iterable<MessagePin> pins,
  Map<String, Message> messagesById,
) {
  final active = pins.where((p) => p.pinned).toList()
    ..sort((a, b) => b.changedAt.compareTo(a.changedAt));
  final shown = <Message>[];
  for (final pin in active) {
    final message = messagesById[pin.messageId];
    if (message == null ||
        message.conversationId != pin.conversationId ||
        message.deleted ||
        !pinnableTypes.contains(message.type)) {
      continue;
    }
    shown.add(message);
    if (shown.length == maxPinsPerConversation) break;
  }
  return shown;
}
