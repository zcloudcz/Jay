import 'package:calltype_core/devices/device_directory.dart';
import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:calltype_core/network/organization_api.dart';
import 'package:calltype_core/network/organization_dtos.dart';
import '../../core/crypto/group_cipher.dart';
import '../../core/crypto/session_manager.dart';
import '../../core/network/api_client.dart';
import '../../core/network/signalr_client.dart';
import '../../core/storage/database.dart';
import 'message_inbox_service.dart';
import 'attachment.dart';

/// Handed to the chat route (`GoRouter` `extra`) by the forward dialog; the
/// route's `create:` sends it once on the freshly created controller.
class ForwardDraft {
  const ForwardDraft({required this.body, required this.type});
  final String body;
  final String type;
}

class ChatController extends ChangeNotifier {
  ChatController({
    required AppDatabase database,
    required SignalRClient signalRClient,
    required SessionManager sessionManager,
    required MessageInboxService inbox,
    required ApiClient apiClient,
    required this.conversationId,
    required DeviceDirectory directory,
  }) : _db = database,
       _signalR = signalRClient,
       _sessions = sessionManager,
       _api = apiClient,
       _directory = directory {
    _subscription =
        (_db.select(_db.messages)
              ..where((m) => m.conversationId.equals(conversationId))
              // 'delete' rows are hidden control messages (see
              // deleteForEveryone); they ride the outbox but are not chat.
              ..where((m) => m.type.equals('delete').not())
              // rowId breaks ties: timestamps are stored with second
              // precision, so a quick answer could otherwise land ABOVE the
              // message it answers.
              ..orderBy([
                (m) => OrderingTerm.desc(m.createdAt),
                (m) => OrderingTerm.desc(m.rowId),
              ]))
            .watch()
            .listen((rows) {
              _messages = rows;
              if (!_disposed) notifyListeners();
            });
    _incoming = inbox.persistedMessages.listen((message) {
      if (message.conversationId == conversationId) _markRead();
    });
    _markRead();
    _syncBusinessInfo();
    _loadGroupMembers();
  }

  /// Backfills the local `organizationId`/`organizationName` cache for this
  /// conversation from the server, once. This is what lets the chat list
  /// badge and this screen's banner appear WITHOUT a network call on every
  /// render — see `Conversations` table doc in `calltype_core` (E05).
  Future<void> _syncBusinessInfo() async {
    final conversation = await (_db.select(
      _db.conversations,
    )..where((c) => c.id.equals(conversationId))).getSingleOrNull();
    if (conversation == null ||
        conversation.type != 'group' ||
        conversation.organizationId != null) {
      return;
    }
    try {
      final info = await _api.getGroupBusinessInfo(conversationId);
      if (!info.isBusiness || _disposed) return;
      await (_db.update(_db.conversations)
            ..where((c) => c.id.equals(conversationId)))
          .write(
            ConversationsCompanion(
              organizationId: Value(info.organizationId),
              organizationName: Value(info.organizationName),
            ),
          );
    } catch (_) {
      // Best-effort cache warm-up; the banner simply won't show yet.
    }
  }

  List<GroupMemberInfo> _groupMembers = [];

  /// Members of this conversation when it is a group (empty for direct chats
  /// and until the one-time load finishes); feeds @mentions and sender names.
  List<GroupMemberInfo> get groupMembers => List.unmodifiable(_groupMembers);

  /// Loads the member profiles once. Best effort like [_syncBusinessInfo]:
  /// offline or an old server just means no suggestions / raw sender ids.
  Future<void> _loadGroupMembers() async {
    try {
      final conversation = await (_db.select(
        _db.conversations,
      )..where((c) => c.id.equals(conversationId))).getSingleOrNull();
      if (conversation?.type != 'group') return;
      final members = await _api.getGroupMemberInfos(conversationId);
      if (_disposed) return;
      _groupMembers = members;
      notifyListeners();
    } catch (_) {}
  }

  /// H2: a business "1:1" is really a business GROUP with exactly one other
  /// non-auditor member plus the auditor — the only shape calls make sense
  /// for (there is no such thing as a group call). Returns that member's
  /// device id, or null when this isn't a business group or has more than
  /// one other member. Not cached: membership can change between opens.
  Future<String?> businessCallTarget() async {
    final info = await _api.getGroupBusinessInfo(conversationId);
    if (!info.isBusiness) return null;
    final members = await _api.getGroupMembers(conversationId);
    final others = members
        .where((id) => id != myIdentityId && id != info.auditorDeviceId)
        .toList();
    return others.length == 1 ? others.single : null;
  }

  final AppDatabase _db;
  final SignalRClient _signalR;
  final SessionManager _sessions;
  final ApiClient _api;
  final String conversationId;
  final DeviceDirectory _directory;

  /// "Me" in this conversation: the IDENTITY id (the primary device id),
  /// which `messages.senderId` stores for every device of this user. Equals
  /// the device id unless this device is a companion; the transport id is
  /// SignalRClient.deviceId.
  String get myIdentityId => _directory.selfIdentityId;

  /// v1: a companion has no calls and no business conversations.
  bool get isCompanion => _directory.isCompanion;
  late StreamSubscription<List<Message>> _subscription;
  late StreamSubscription<Message> _incoming;
  bool _disposed = false;
  List<Message> _messages = [];
  List<Message> get messages => List.unmodifiable(_messages);
  static const _uuid = Uuid();

  /// Set when the hub rejects a send with `audit_recipient_missing` (Jay
  /// Business mode, KB1) — the archiver was dropped from the fan-out, which
  /// must never happen silently. Cleared on the next send attempt.
  bool _auditRecipientMissing = false;
  bool get auditRecipientMissing => _auditRecipientMissing;

  /// One-shot read: the UI calls this to show its snackbar exactly once per
  /// failure, instead of re-showing it on every rebuild while the flag
  /// stays true.
  bool consumeAuditRecipientMissing() {
    final value = _auditRecipientMissing;
    _auditRecipientMissing = false;
    return value;
  }

  /// Set when the hub rejects a send with `auditor_unavailable` (Jay
  /// Business mode, W2-F fail-closed rule) — the organization's auditor is
  /// not alive right now. Deliberately a SEPARATE flag from
  /// [auditRecipientMissing]: the two causes need distinct wording (one is a
  /// tamper/bug signal, the other an availability problem the user can just
  /// retry). Cleared on the next send attempt.
  bool _auditorUnavailable = false;
  bool get auditorUnavailable => _auditorUnavailable;

  /// One-shot read, same contract as [consumeAuditRecipientMissing].
  bool consumeAuditorUnavailable() {
    final value = _auditorUnavailable;
    _auditorUnavailable = false;
    return value;
  }

  /// Set when the hub/REST rejects a send/group action with
  /// `business_conversation_required` (Jay Business mode, P1 —
  /// `Organization.RequireBusinessConversations`): the recipient is enrolled
  /// in an organization that only allows this pair to talk inside a business
  /// conversation. Deliberately a separate flag — unlike
  /// [auditRecipientMissing]/[auditorUnavailable] this is not a failure to
  /// retry, it's a redirect: the UI offers to open/create the business
  /// conversation instead (see [createBusinessConversationWithPeer]).
  bool _businessConversationRequired = false;
  bool get businessConversationRequired => _businessConversationRequired;

  /// One-shot read, same contract as [consumeAuditRecipientMissing].
  bool consumeBusinessConversationRequired() {
    final value = _businessConversationRequired;
    _businessConversationRequired = false;
    return value;
  }

  /// P1 UI action: finds the organization both the caller and the peer are
  /// actively enrolled in (there is exactly one that could have triggered
  /// `business_conversation_required` for a 1:1 conversation) and creates a
  /// two-member business group with them — the same call the "new business
  /// chat" flow uses. Only meaningful for a 1:1 conversation, where
  /// [conversationId] IS the peer's device id. Returns the new group's id, or
  /// null if no shared organization could be found (should not happen if the
  /// server just rejected the send for this reason, but network state can
  /// have moved on).
  Future<String?> createBusinessConversationWithPeer() async {
    final myOrgs = await _api.getMyOrganizations();
    for (final org in myOrgs) {
      final enrollments = await _api.getOrganizationEnrollments(
        org.organizationId,
      );
      if (enrollments.any((e) => e.deviceId == conversationId)) {
        final response = await _api.createGroup('', [
          conversationId,
        ], organizationId: org.organizationId);
        return response['groupId'] as String;
      }
    }
    return null;
  }

  Future<void> _markRead() async {
    await (_db.update(_db.conversations)
          ..where((c) => c.id.equals(conversationId)))
        .write(const ConversationsCompanion(unreadCount: Value(0)));
  }

  Message? _replyingTo;

  /// The message the next sent message will quote, or null.
  Message? get replyingTo => _replyingTo;

  void startReply(Message message) {
    _replyingTo = message;
    notifyListeners();
  }

  void cancelReply() {
    if (_replyingTo == null) return;
    _replyingTo = null;
    notifyListeners();
  }

  /// What a quote of [message] shows: the text, or the file name for a file,
  /// cut to [maxReplyPreview]. It is copied into the outgoing payload because
  /// the receiver may not have the original.
  static String replyPreviewOf(Message message) {
    var text = message.body ?? '';
    if (message.type == 'file') {
      try {
        text = Attachment.decode(text).name;
      } catch (_) {
        text = '';
      }
    }
    return text.length > maxReplyPreview
        ? text.substring(0, maxReplyPreview)
        : text;
  }

  Future<void> sendMessage(String text) => _send(text, 'text');

  Future<void> sendAttachment(String name, Uint8List bytes) =>
      _send(Attachment(name: name, bytes: bytes).encode(), 'file');

  /// Sends [body] into THIS conversation marked as forwarded. The forward UI
  /// navigates to the target chat first and calls this on that chat's own
  /// controller (a second controller would mark the conversation read).
  Future<void> sendForwarded({required String body, required String type}) =>
      _send(body, type, forwarded: true);

  /// Removes the message from this device only. Works for any message,
  /// including tombstones and failed sends (also drops its pending outbox).
  Future<void> deleteForMe(String messageId) => _db.transaction(() async {
    await (_db.delete(_db.messages)..where((m) => m.id.equals(messageId))).go();
    await (_db.delete(
      _db.backupState,
    )..where((s) => s.key.equals('outbox:$messageId'))).go();
  });

  /// Deletes an own, already sent message for every participant by sending a
  /// `delete` control message through the normal encrypted pipeline. Returns
  /// false (and leaves the original untouched) if it is not allowed or the
  /// send failed, so the UI can say so.
  Future<bool> deleteForEveryone(String messageId) async {
    final target = await (_db.select(
      _db.messages,
    )..where((m) => m.id.equals(messageId))).getSingleOrNull();
    if (target == null ||
        target.senderId != myIdentityId ||
        target.conversationId != conversationId ||
        target.deleted ||
        target.type == 'call-event' ||
        target.type == 'delete' ||
        target.status == 'sending' ||
        target.status == 'failed') {
      return false;
    }
    final conversation = await (_db.select(
      _db.conversations,
    )..where((c) => c.id.equals(conversationId))).getSingleOrNull();
    if (conversation == null || conversation.organizationId != null) {
      return false;
    }
    if (conversation.type == 'group') {
      // The cached organizationId may simply not be filled in yet. Fail
      // CLOSED: business messages are archived and must never be retracted.
      // Asked directly instead of through getGroupBusinessInfo: that helper
      // turns a network error into "not business", which here would mean
      // failing OPEN.
      try {
        final response = await _api.transport.get<Map<String, dynamic>>(
          '/groups/$conversationId',
        );
        if (GroupBusinessInfo.fromJson(response.data!).isBusiness) {
          return false;
        }
      } catch (_) {
        return false;
      }
    }
    // A local row of type 'delete' reuses the outbox, so a retry resends the
    // SAME ciphertext and the receiver's redelivery marker keeps it idempotent.
    // It deliberately does not touch lastMessageAt.
    final controlId = _uuid.v4();
    await _db
        .into(_db.messages)
        .insert(
          MessagesCompanion.insert(
            id: controlId,
            conversationId: conversationId,
            senderId: myIdentityId,
            body: Value(messageId),
            type: const Value('delete'),
            status: const Value('sending'),
            createdAt: DateTime.now(),
          ),
        );
    await retryMessage(controlId);
    final control = await (_db.select(
      _db.messages,
    )..where((m) => m.id.equals(controlId))).getSingleOrNull();
    final sent = control?.status == 'sent';
    await _db.transaction(() async {
      // Only after a successful send does the original change, exactly like
      // on the receiving side.
      if (sent) await tombstoneMessage(_db, messageId);
      await (_db.delete(
        _db.messages,
      )..where((m) => m.id.equals(controlId))).go();
      await (_db.delete(
        _db.backupState,
      )..where((s) => s.key.equals('outbox:$controlId'))).go();
    });
    return sent;
  }

  Future<void> _send(String text, String type, {bool forwarded = false}) async {
    if (text.trim().isEmpty) return;
    final id = _uuid.v4();
    final now = DateTime.now();
    final reply = forwarded ? null : _replyingTo;
    if (reply != null) cancelReply();
    await _db.transaction(() async {
      await _db
          .into(_db.messages)
          .insert(
            MessagesCompanion.insert(
              id: id,
              conversationId: conversationId,
              senderId: myIdentityId,
              body: Value(text),
              type: Value(type),
              status: const Value('sending'),
              createdAt: now,
              replyToId: Value(reply?.id),
              replySenderId: Value(reply?.senderId),
              replyPreview: Value(reply == null ? null : replyPreviewOf(reply)),
              forwarded: Value(forwarded),
            ),
          );
      await (_db.update(_db.conversations)
            ..where((c) => c.id.equals(conversationId)))
          .write(ConversationsCompanion(lastMessageAt: Value(now)));
    });
    await retryMessage(id);
  }

  Future<void> retryMessage(
    String messageId,
  ) => MessageProcessingQueue.forDatabase(_db).run(() async {
    final message = await (_db.select(
      _db.messages,
    )..where((m) => m.id.equals(messageId))).getSingle();
    if (message.senderId != myIdentityId ||
        message.conversationId != conversationId ||
        (message.status != 'failed' && message.status != 'sending')) {
      return;
    }
    await _status(messageId, 'sending');
    _auditRecipientMissing = false;
    _auditorUnavailable = false;
    _businessConversationRequired = false;
    try {
      var stored = await (_db.select(
        _db.backupState,
      )..where((s) => s.key.equals('outbox:$messageId'))).getSingleOrNull();
      if (stored == null) {
        final conversation = await (_db.select(
          _db.conversations,
        )..where((c) => c.id.equals(conversationId))).getSingle();
        final groupId = conversation.type == 'group' ? conversationId : null;
        final recipients = groupId == null
            ? [conversationId]
            : (await _api.getGroupMembers(
                groupId,
              )).where((id) => id != myIdentityId).toList();
        if (recipients.isEmpty) {
          throw StateError('No recipients in this conversation');
        }
        final payload = jsonEncode({
          'v': 1,
          'id': messageId,
          'body': message.body,
          'type': message.type,
          'groupId': groupId,
          'groupName': groupId == null ? null : conversation.title,
          'createdAt': message.createdAt.toUtc().toIso8601String(),
          // Additive keys: old clients ignore them and show a normal message.
          if (message.replyToId != null)
            'replyTo': {
              'id': message.replyToId,
              'senderId': message.replySenderId,
              'preview': message.replyPreview ?? '',
            },
          if (message.forwarded) 'forwarded': true,
        });
        await _db.transaction(() async {
          final envelopes = <String, String>{};
          if (groupId != null) {
            final encrypted = await GroupCipher(
              sessionManager: _sessions,
              ensureSession: _ensureSession,
            ).encryptForGroup(groupId, recipients, payload);
            envelopes.addAll(
              encrypted.map((id, bytes) => MapEntry(id, base64Encode(bytes))),
            );
          } else {
            await _ensureSession(conversationId);
            envelopes[conversationId] = base64Encode(
              utf8.encode(
                await _sessions.encryptMessage(conversationId, payload),
              ),
            );
          }
          await _db
              .into(_db.backupState)
              .insert(
                BackupStateCompanion.insert(
                  key: 'outbox:$messageId',
                  value: jsonEncode({
                    'groupId': groupId,
                    'envelopes': envelopes,
                  }),
                ),
              );
        });
        stored = await (_db.select(
          _db.backupState,
        )..where((s) => s.key.equals('outbox:$messageId'))).getSingle();
      }
      final outbox = jsonDecode(stored.value) as Map<String, dynamic>;
      final envelopes = (outbox['envelopes'] as Map<String, dynamic>)
          .cast<String, String>();
      final groupId = outbox['groupId'] as String?;
      if (groupId != null) {
        // The whole fan-out in one call (see sendGroupMessage): a business
        // group rejects any call without the auditor's envelope (KB2).
        await _signalR.sendGroupMessage(
          groupId,
          envelopes,
          messageId: messageId,
        );
      } else {
        await _signalR.sendMessage(
          envelopes.keys.single,
          envelopes.values.single,
          messageId: messageId,
        );
      }
      await _db.transaction(() async {
        await _status(messageId, 'sent');
        await (_db.delete(
          _db.backupState,
        )..where((s) => s.key.equals('outbox:$messageId'))).go();
      });
    } catch (e) {
      // The hub reports the audit failure as a plain-text HubException
      // message; surfacing it distinctly (rather than a generic "failed")
      // is required by KB1 — this must never look like an ordinary
      // delivery hiccup the user can ignore.
      if (e.toString().contains('audit_recipient_missing')) {
        _auditRecipientMissing = true;
        notifyListeners();
      } else if (e.toString().contains('auditor_unavailable')) {
        _auditorUnavailable = true;
        notifyListeners();
      } else if (e.toString().contains('business_conversation_required')) {
        _businessConversationRequired = true;
        notifyListeners();
      }
      await _status(messageId, 'failed');
    }
  });

  Future<void> _status(String id, String status) =>
      (_db.update(_db.messages)..where((m) => m.id.equals(id)))
          .write(MessagesCompanion(status: Value(status)))
          .then((_) {});

  Future<void> _ensureSession(String recipient) async {
    if (!await _sessions.hasSession(recipient)) {
      await _sessions.initiateSession(
        recipient,
        await _api.getKeyBundle(recipient),
      );
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _subscription.cancel();
    _incoming.cancel();
    super.dispose();
  }
}
