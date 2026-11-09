import 'dart:async';

import 'package:calltype_core/devices/device_directory.dart';
import 'package:calltype_core/messaging/chat_deleted.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';

import '../devices/own_device_sender.dart';
import '../media/media_cleanup.dart';
import '../media/media_service.dart';
import 'message_inbox_service.dart' show MessageProcessingQueue;
import 'message_sender.dart' show sendFailPrefix;
import 'read_sync.dart' show readUpToPrefix;

/// BackupState key prefix of a deleted chat:
/// `chat-deleted:<conversationId>` = ms of the newest deletion. A contact
/// sync snapshot carries conversation HEADERS without a time, so an older
/// device's snapshot must not bring an empty, deleted chat back. A new
/// message still recreates the chat (spec 2026-11-09-delete-chats-contacts
/// D3): the inbox does not look at this key.
const chatDeletedPrefix = 'chat-deleted:';

/// What a chat deletion removed: the media bodies whose local files can go
/// once the transaction committed, and whether the conversation row went.
class ChatDeletion {
  const ChatDeletion({
    required this.removedMedia,
    required this.conversationRemoved,
    required this.changed,
  });

  /// `(messageId, body)` of every removed `media` row.
  final List<(String, String?)> removedMedia;
  final bool conversationRemoved;

  /// Whether anything was deleted at all.
  final bool changed;
}

/// Deletes the local copy of [conversationId] (spec D1/D2). Runs inside the
/// caller's transaction (or its own): the messages with `createdAt` up to
/// [upTo] (all when null) and everything that hangs on them (reactions,
/// pins, poll votes, outbox/extra/upload/send-failure state). The
/// conversation row and its per-chat state (draft, read state) go when no
/// message is left; otherwise the unread count is capped at the incoming
/// messages that are left.
///
/// Media files are NOT touched here (they are not database state); call
/// [deleteRemovedMedia] after the transaction committed.
Future<ChatDeletion> deleteConversationRows(
  AppDatabase db,
  String conversationId, {
  int? upTo,
  required int deletedAt,
  String? selfIdentityId,
}) async {
  final conversation = await (db.select(
    db.conversations,
  )..where((c) => c.id.equals(conversationId))).getSingleOrNull();
  final rows =
      await (db.select(db.messages)..where(
            (m) =>
                m.conversationId.equals(conversationId) &
                (upTo == null
                    ? const Constant(true)
                    : m.createdAt.isSmallerOrEqualValue(
                        DateTime.fromMillisecondsSinceEpoch(upTo),
                      )),
          ))
          .get();
  final ids = [for (final m in rows) m.id];
  final removedMedia = [
    for (final m in rows)
      if (m.type == 'media') (m.id, m.body),
  ];
  // Chunked: SQLite allows a limited number of variables per statement and
  // a chat can hold thousands of messages.
  for (var i = 0; i < ids.length; i += 500) {
    final chunk = ids.sublist(i, i + 500 > ids.length ? ids.length : i + 500);
    await (db.delete(
      db.messageReactions,
    )..where((r) => r.messageId.isIn(chunk))).go();
    await (db.delete(
      db.messagePins,
    )..where((p) => p.messageId.isIn(chunk))).go();
    await (db.delete(db.pollVotes)..where((v) => v.pollId.isIn(chunk))).go();
    await (db.delete(db.backupState)..where(
          (s) => s.key.isIn([
            for (final id in chunk) ...[
              'outbox:$id',
              'extra:$id',
              'mediaup:$id',
              '$sendFailPrefix$id',
            ],
          ]),
        ))
        .go();
    await (db.delete(db.messages)..where((m) => m.id.isIn(chunk))).go();
  }
  final left = await (db.select(
    db.messages,
  )..where((m) => m.conversationId.equals(conversationId))).get();
  var conversationRemoved = false;
  if (left.isEmpty) {
    // Reactions/pins/votes for messages this device never had (they may
    // overtake their target) belong to the deleted chat too.
    await (db.delete(
      db.messageReactions,
    )..where((r) => r.conversationId.equals(conversationId))).go();
    await (db.delete(
      db.messagePins,
    )..where((p) => p.conversationId.equals(conversationId))).go();
    await (db.delete(
      db.pollVotes,
    )..where((v) => v.conversationId.equals(conversationId))).go();
    await (db.delete(db.backupState)..where(
          (s) => s.key.isIn([
            'draft:$conversationId',
            '$readUpToPrefix$conversationId',
          ]),
        ))
        .go();
    if (conversation != null) {
      await (db.delete(
        db.conversations,
      )..where((c) => c.id.equals(conversationId))).go();
      conversationRemoved = true;
    }
  } else if (conversation != null) {
    final self = conversation.unreadCount;
    // Incoming, countable messages that survived (an own message or a call
    // log line never counted as unread).
    final incoming = left
        .where(
          (m) =>
              m.senderId != selfIdentityId &&
              m.type != 'call-event' &&
              !m.deleted,
        )
        .length;
    if (incoming < self) {
      await (db.update(db.conversations)
            ..where((c) => c.id.equals(conversationId)))
          .write(ConversationsCompanion(unreadCount: Value(incoming)));
    }
  }
  if (conversation != null || ids.isNotEmpty) {
    await _rememberDeletion(db, conversationId, deletedAt);
  }
  return ChatDeletion(
    removedMedia: removedMedia,
    conversationRemoved: conversationRemoved,
    changed: conversationRemoved || ids.isNotEmpty,
  );
}

Future<void> _rememberDeletion(
  AppDatabase db,
  String conversationId,
  int deletedAt,
) async {
  final key = '$chatDeletedPrefix$conversationId';
  final previous = await (db.select(
    db.backupState,
  )..where((s) => s.key.equals(key))).getSingleOrNull();
  final known = previous == null ? null : int.tryParse(previous.value);
  if (known != null && known >= deletedAt) return;
  await db
      .into(db.backupState)
      .insertOnConflictUpdate(
        BackupStateCompanion.insert(key: key, value: '$deletedAt'),
      );
}

/// Whether [conversationId] was deleted here (a snapshot must not bring its
/// header back).
Future<bool> wasChatDeleted(AppDatabase db, String conversationId) async =>
    await (db.select(db.backupState)
          ..where((s) => s.key.equals('$chatDeletedPrefix$conversationId')))
        .getSingleOrNull() !=
    null;

/// Removes the local files of the media a deletion removed, unless another
/// message still references them (a forwarded copy). Best effort.
Future<void> deleteRemovedMedia(
  AppDatabase db,
  MediaService media,
  List<(String, String?)> removed,
) async {
  for (final (id, body) in removed) {
    media.cancelUpload(id);
    await deleteUnreferencedMedia(db, media, body, id);
  }
}

/// Applies a `chat-deleted` from another own device (spec D2). Runs inside
/// the inbox transaction. An unknown conversation is ignored; only messages
/// created up to `deletedAt` go, so one that arrived later survives.
///
/// Granularity: drift stores `createdAt` in whole seconds, so a message
/// created in the same second as the deletion counts as older and goes too
/// (spec Limits).
Future<ChatDeletion> applyChatDeleted(
  AppDatabase db,
  ChatDeletedPayload payload, {
  required String selfIdentityId,
}) async {
  final known = await (db.select(
    db.conversations,
  )..where((c) => c.id.equals(payload.conversationId))).getSingleOrNull();
  if (known == null) {
    return const ChatDeletion(
      removedMedia: [],
      conversationRemoved: false,
      changed: false,
    );
  }
  return deleteConversationRows(
    db,
    payload.conversationId,
    upTo: payload.deletedAt,
    deletedAt: payload.deletedAt,
    selfIdentityId: selfIdentityId,
  );
}

/// Outcome of [ChatDeletionService.leaveGroup].
enum LeaveGroupResult {
  /// Left (or was no member any more) and the chat is deleted here.
  left,

  /// The server keeps at least one admin and this identity is the only one.
  lastAdmin,

  /// Network or server error; nothing was deleted.
  failed,
}

/// Deletes chats on this identity (spec 2026-11-09-delete-chats-contacts):
/// locally, then on the other own devices with a `chat-deleted` message.
/// App-wide, like [ReadStateService].
class ChatDeletionService {
  ChatDeletionService({
    required AppDatabase database,
    required OwnDeviceSender? sender,
    required DeviceDirectory? Function() directory,
    ApiClient? apiClient,
    MediaService? media,
    void Function(String conversationId)? onDeleted,
    DateTime Function()? clock,
  }) : _db = database,
       _sender = sender,
       _directory = directory,
       _api = apiClient,
       _media = media,
       _onDeleted = onDeleted,
       _clock = clock ?? DateTime.now;

  final AppDatabase _db;

  /// Null in tests that only check the local part.
  final OwnDeviceSender? _sender;

  /// Null until onboarding opened the device directory.
  final DeviceDirectory? Function() _directory;
  final ApiClient? _api;
  final MediaService? _media;

  /// Told after a chat was deleted here (its notifications can go).
  final void Function(String conversationId)? _onDeleted;
  final DateTime Function() _clock;

  /// Deletes [conversationId] on this identity. The other participants keep
  /// their copy. Returns whether the other own devices were told (false
  /// when there are none or the send is still queued for a retry).
  Future<bool> deleteChat(String conversationId) async {
    final deletedAt = _clock().millisecondsSinceEpoch;
    // In the inbox queue, so a message being stored right now cannot slip
    // in between the read and the delete of the same rows.
    final deletion = await MessageProcessingQueue.forDatabase(_db).run(
      () => _db.transaction(
        () => deleteConversationRows(
          _db,
          conversationId,
          deletedAt: deletedAt,
          selfIdentityId: _directory()?.selfIdentityId,
        ),
      ),
    );
    await deleteRemovedMedia(
      _db,
      _media ?? MediaService.instance,
      deletion.removedMedia,
    );
    _onDeleted?.call(conversationId);
    return _tellOwnDevices(conversationId, deletedAt);
  }

  Future<bool> _tellOwnDevices(String conversationId, int deletedAt) async {
    final sender = _sender;
    if (sender == null || _directory() == null) return false;
    try {
      // No companions: nothing to tell, and the hub refuses an empty
      // fan-out.
      if ((await sender.otherDevices()).isEmpty) return false;
      // A failed send stays in the own-device outbox and goes out on the
      // next reconnect (OwnDeviceSender.resendPending).
      return await sender.send(
        chatDeletedType,
        ChatDeletedPayload(
          conversationId: conversationId,
          deletedAt: deletedAt,
        ).encode(),
      );
    } catch (_) {
      return false;
    }
  }

  /// Leaves group [groupId] for this identity (spec D5): removes each own
  /// device that is a member (in practice the primary; a companion removes
  /// it on the identity's behalf), then deletes the chat here and on the
  /// other own devices. A group this identity is no member of any more is
  /// simply deleted.
  Future<LeaveGroupResult> leaveGroup(String groupId) async {
    final api = _api;
    final directory = _directory();
    if (api == null || directory == null) return LeaveGroupResult.failed;
    List<GroupMemberInfo> members;
    try {
      members = await api.getGroupMemberInfos(groupId);
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      // 403: not a member (left already, or removed); 404: no such group.
      if (status == 403 || status == 404) {
        await deleteChat(groupId);
        return LeaveGroupResult.left;
      }
      return LeaveGroupResult.failed;
    } catch (_) {
      return LeaveGroupResult.failed;
    }
    final own = {
      directory.selfIdentityId.toLowerCase(),
      directory.selfDeviceId.toLowerCase(),
      for (final d in await directory.devicesOf(directory.selfIdentityId))
        d.toLowerCase(),
    };
    for (final member in members) {
      if (!own.contains(member.deviceId.toLowerCase())) continue;
      try {
        await api.removeGroupMember(groupId, member.deviceId);
      } on DioException catch (e) {
        final status = e.response?.statusCode;
        final data = e.response?.data;
        if (status == 404 || status == 403) continue;
        if (status == 409 && data is Map && data['code'] == 'last_admin') {
          return LeaveGroupResult.lastAdmin;
        }
        return LeaveGroupResult.failed;
      } catch (_) {
        return LeaveGroupResult.failed;
      }
    }
    await deleteChat(groupId);
    return LeaveGroupResult.left;
  }
}
