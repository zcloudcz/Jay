import 'package:calltype_core/messaging/control_messages.dart';
import 'package:drift/drift.dart';

import '../../../core/storage/database.dart';
import '../attachment.dart';
import 'inbound_handler.dart';

/// Stores a content message (`text`, `file`, `call-event`, and — per
/// contracts K1 — any content type this version does not know) as a row
/// in `Messages`, creating the conversation on first contact.
///
/// One class for all of them on purpose: they differ only in validation
/// and in whether they count as unread, and stream M/M2 handlers for new
/// content types (`media`, replies) can reuse [storeContent].
class ContentMessageHandler implements InboundTypeHandler {
  const ContentMessageHandler({this.validate, this.countsAsUnread = true});

  /// Throws [FormatException] when the body is malformed.
  final void Function(String body)? validate;

  /// A `call-event` is a log line, not something to "read" (H2).
  final bool countsAsUnread;

  /// `text`: any string.
  static const text = ContentMessageHandler();

  /// `file`: inline attachment `{name, data}` (Attachment).
  static final file = ContentMessageHandler(validate: _validateFile);

  /// `call-event` (H1/H2): a finished/missed business call.
  static const callEvent = ContentMessageHandler(countsAsUnread: false);

  /// A content type unknown to this version (K1): stored verbatim with its
  /// original `type` and `body`, rendered as "needs a newer version of Jay"
  /// until an update knows how to show it — the row is not lost.
  static const unknown = ContentMessageHandler();

  static void _validateFile(String body) {
    try {
      Attachment.decode(body);
    } on FormatException {
      rethrow;
    } catch (e) {
      // Attachment reports bad names/sizes as ArgumentError (sender-side
      // API); for a received message that is "malformed" (ack + drop).
      throw FormatException('Invalid file attachment: $e');
    }
  }

  @override
  Future<InboundResult> handle(InboundContext ctx) async {
    validate?.call(ctx.body);
    return StoredContent(
      await storeContent(ctx, countsAsUnread: countsAsUnread),
    );
  }

  /// Writes the row + conversation bookkeeping and returns the stored row.
  static Future<Message> storeContent(
    InboundContext ctx, {
    bool countsAsUnread = true,
  }) async {
    final db = ctx.db;
    final isGroup = ctx.groupId != null;
    final conversation = await (db.select(
      db.conversations,
    )..where((c) => c.id.equals(ctx.conversationId))).getSingleOrNull();
    if (conversation == null) {
      await db
          .into(db.conversations)
          .insert(
            ConversationsCompanion.insert(
              id: ctx.conversationId,
              type: isGroup ? 'group' : 'direct',
              title: Value(
                isGroup ? ctx.payload['groupName'] as String? : null,
              ),
            ),
          );
    } else if (conversation.type != (isGroup ? 'group' : 'direct')) {
      throw const FormatException('Conflicting conversation type');
    }
    await db
        .into(db.messages)
        .insert(
          MessagesCompanion.insert(
            id: ctx.messageId,
            conversationId: ctx.conversationId,
            senderId: ctx.senderId,
            body: Value(ctx.body),
            type: Value(ctx.type),
            // Content synced from my own device is MY message (D): it was
            // already sent, and there is nothing to receipt or to read.
            status: Value(ctx.fromOwnDevice ? 'sent' : 'delivered'),
            createdAt: ctx.senderCreatedAt,
            receivedAt: Value(ctx.now),
          ),
        );
    final unread = countsAsUnread && !ctx.fromOwnDevice ? 1 : 0;
    await (db.update(
      db.conversations,
    )..where((c) => c.id.equals(ctx.conversationId))).write(
      ConversationsCompanion(
        lastMessageAt: Value(ctx.now),
        unreadCount: Value((conversation?.unreadCount ?? 0) + unread),
      ),
    );
    return (db.select(
      db.messages,
    )..where((m) => m.id.equals(ctx.messageId))).getSingle();
  }
}

/// Content types this version can RENDER. Anything else stored in
/// `Messages` shows the "needs a newer version" placeholder (K1).
const renderableContentTypes = {
  MessageTypes.text,
  MessageTypes.file,
  MessageTypes.callEvent,
};
