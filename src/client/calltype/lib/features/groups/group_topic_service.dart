import 'package:calltype_core/devices/device_directory.dart';
import 'package:calltype_core/messaging/group_topic.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/network/group_dtos.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../chat/message_sender.dart';
import '../chat/resend_service.dart';
import 'group_topic_store.dart';

/// Why setting a topic failed before anything was sent. The screens map it
/// to a localized message (controllers have no BuildContext).
enum GroupTopicError {
  /// 403: this device is not an admin (or a companion, which never is).
  notAdmin,

  /// 404 from `PUT /groups/{id}/topic`: a server from before group topics.
  unsupported,

  /// A business group (409 `business_group`, or known locally): no topics
  /// in v1 (spec row 11).
  business,

  /// More than [maxGroupTopicLength] characters after trimming.
  tooLong,

  /// Network failure, 5xx, anything unexpected.
  failed,
}

/// What [GroupTopicService.setTopic] did.
enum GroupTopicSent {
  /// Recorded, stored here and sent to every member device.
  sent,

  /// Recorded and stored here; the send failed for now and the transient
  /// control row is retried by the automatic resend (spec row 14). The
  /// server keeps the version, so a late retry is still accepted.
  queued,
}

class GroupTopicResult {
  const GroupTopicResult.sent(this.sent) : error = null;
  const GroupTopicResult.failed(this.error) : sent = null;

  final GroupTopicSent? sent;
  final GroupTopicError? error;
  bool get ok => error == null;
}

/// Sender side of group topics (spec 2026-11-13-group-topics row 14):
/// `PUT /groups/{id}/topic` records a version, then the content goes E2E as
/// a `group-topic` control message through the normal group fan-out (own
/// other devices included) and is stored here at once.
///
/// App-wide and not bound to a chat screen, because the group create screen
/// and Group info set topics without an open chat.
class GroupTopicService {
  GroupTopicService({
    required AppDatabase database,
    required ApiClient apiClient,
    required MessageSender Function() sender,
    required DeviceDirectory Function() directory,
    ResendService? resend,
  }) : _db = database,
       _api = apiClient,
       _sender = sender,
       _directory = directory,
       _resend = resend;

  final AppDatabase _db;
  final ApiClient _api;
  final MessageSender Function() _sender;
  final DeviceDirectory Function() _directory;
  final ResendService? _resend;
  static const _uuid = Uuid();

  /// Sets the topic of [groupId] to [topic] (trimmed; empty clears it).
  Future<GroupTopicResult> setTopic(String groupId, String topic) async {
    final text = topic.trim();
    if (text.length > maxGroupTopicLength) {
      return const GroupTopicResult.failed(GroupTopicError.tooLong);
    }
    final conversation = await (_db.select(
      _db.conversations,
    )..where((c) => c.id.equals(groupId))).getSingleOrNull();
    if (conversation == null || conversation.type != 'group') {
      return const GroupTopicResult.failed(GroupTopicError.failed);
    }
    if (conversation.organizationId != null) {
      return const GroupTopicResult.failed(GroupTopicError.business);
    }
    final GroupTopicRecord record;
    try {
      record = await _api.recordGroupTopic(groupId);
    } on DioException catch (e) {
      // On a PUT failure nothing is sent and nothing stored (spec row 14).
      final data = e.response?.data;
      final code = data is Map ? (data['code'] ?? data['error']) : null;
      return GroupTopicResult.failed(switch (e.response?.statusCode) {
        403 => GroupTopicError.notAdmin,
        404 => GroupTopicError.unsupported,
        409 when code == 'business_group' => GroupTopicError.business,
        _ => GroupTopicError.failed,
      });
    } catch (_) {
      return const GroupTopicResult.failed(GroupTopicError.failed);
    }
    final me = _directory().selfIdentityId;
    final controlId = _uuid.v4();
    final registry = OutboxRegistry.forDatabase(_db);
    // Held while this flow runs, so the automatic resend does not send the
    // same row in parallel (R7); released before returning, after which a
    // failed row is the resend's to retry.
    registry.hold(controlId);
    try {
      await _db.transaction(() async {
        // Applied at once: the server already names this device's identity
        // as the author of this version, so it is the current topic.
        await writeGroupTopicIfNewer(
          _db,
          groupId,
          StoredGroupTopic(
            topic: text,
            version: record.version,
            setBy: me.toLowerCase(),
          ),
        );
        await _db
            .into(_db.messages)
            .insert(
              MessagesCompanion.insert(
                id: controlId,
                conversationId: groupId,
                senderId: me,
                body: Value(
                  GroupTopicPayload(
                    topic: text,
                    version: record.version,
                  ).encode(),
                ),
                type: const Value(groupTopicType),
                status: const Value('sending'),
                createdAt: DateTime.now(),
              ),
            );
      });
      final outcome = await _sender().send(controlId);
      _resend?.attempted(controlId, outcome);
      switch (outcome.status) {
        case SendStatus.sent:
          await dropControlRow(_db, controlId);
          return const GroupTopicResult.sent(GroupTopicSent.sent);
        case SendStatus.permanent:
          // Cannot succeed (e.g. no other member left): stop retrying.
          await dropControlRow(_db, controlId);
          return const GroupTopicResult.failed(GroupTopicError.failed);
        case SendStatus.transient:
        case SendStatus.skipped:
          return const GroupTopicResult.sent(GroupTopicSent.queued);
      }
    } finally {
      registry.release(controlId);
    }
  }
}
