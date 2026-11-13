import 'package:calltype_core/messaging/group_topic.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/network/group_dtos.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';

import 'group_topic_store.dart';

/// Receiver side of a `group-topic` control message (spec
/// 2026-11-13-group-topics, "Wire shapes", receiver rules 1-5). Kept out of
/// MessageInboxService so the hot inbox file only gets a hook.
///
/// Runs inside the inbox transaction. Every refusal simply returns (the
/// caller acks it and writes the `control:` marker); only a transient
/// failure of the server check throws, which rolls the transaction back
/// (ratchet step included) and leaves the message queued for a retry.
/// Returns whether a topic was stored.
Future<bool> applyGroupTopic(
  AppDatabase db, {
  required ApiClient? api,
  required Map<String, dynamic> payload,
  required String? groupId,
  required String conversationId,
  required String senderIdentityId,
}) async {
  // Rule 1: groups only, and a body that decodes.
  if (groupId == null) return false;
  final topic = GroupTopicPayload.decode(payload['body']);
  if (topic == null) return false;
  final conversation = await (db.select(
    db.conversations,
  )..where((c) => c.id.equals(conversationId))).getSingleOrNull();
  // Rule 2: no topics in business conversations (v1, row 11), and the id
  // must not name a 1:1 conversation.
  if (conversation != null &&
      (conversation.organizationId != null || conversation.type != 'group')) {
    return false;
  }
  // Without an API the server record cannot be checked, and unverified
  // content must never be shown (row 6): drop it.
  if (api == null) return false;
  // Rule 3: the server's CURRENT record (never a cache) must name exactly
  // this version and this sender. The sender is the AUTHENTICATED identity,
  // never a field of the body, so a non-admin cannot set a topic and a
  // replayed old version is refused.
  final GroupDetails details;
  try {
    details = await api.getGroup(groupId);
  } on DioException catch (e) {
    final status = e.response?.statusCode;
    // 403/404: no longer a member or no such group. A retry cannot change
    // that, so the message is dropped (acked) instead of staying queued.
    if (status != null && status >= 400 && status < 500 && status != 429) {
      return false;
    }
    rethrow;
  }
  final record = details.topic;
  if (record == null || !record.matches(topic.version, senderIdentityId)) {
    return false;
  }
  // Business groups have no recorded topic (409 on PUT), but an unknown
  // conversation cannot be checked locally, so the server's answer decides.
  if (details.raw['organizationId'] != null) return false;
  // Rule 4 + 5: newer than the stored version, else a no-op.
  final written = await writeGroupTopicIfNewer(
    db,
    conversationId,
    StoredGroupTopic(
      topic: topic.topic,
      version: topic.version,
      setBy: senderIdentityId.toLowerCase(),
    ),
  );
  // Row 10: a valid topic for a group this device does not know yet opens
  // the group conversation, like a first text message would, but never
  // counts as unread (unreadCount stays at its default 0).
  if (conversation == null) {
    final name = payload['groupName'];
    await db
        .into(db.conversations)
        .insert(
          ConversationsCompanion.insert(
            id: conversationId,
            type: 'group',
            title: Value(name is String ? name : null),
            // Sorted like a group that just got its first message, so the
            // new topic group shows at the top of the chat list.
            lastMessageAt: Value(DateTime.now()),
          ),
        );
  }
  return written;
}
