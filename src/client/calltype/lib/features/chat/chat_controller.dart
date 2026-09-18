import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:calltype_core/network/organization_api.dart';
import '../../core/crypto/group_cipher.dart';
import '../../core/crypto/session_manager.dart';
import '../../core/network/api_client.dart';
import '../../core/network/signalr_client.dart';
import '../../core/storage/database.dart';
import 'message_inbox_service.dart';
import 'attachment.dart';

class ChatController extends ChangeNotifier {
  ChatController({
    required AppDatabase database,
    required SignalRClient signalRClient,
    required SessionManager sessionManager,
    required MessageInboxService inbox,
    required ApiClient apiClient,
    required this.conversationId,
    required this.myDeviceId,
  }) : _db = database,
       _signalR = signalRClient,
       _sessions = sessionManager,
       _api = apiClient {
    _subscription =
        (_db.select(_db.messages)
              ..where((m) => m.conversationId.equals(conversationId))
              ..orderBy([(m) => OrderingTerm.desc(m.createdAt)]))
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
  final AppDatabase _db;
  final SignalRClient _signalR;
  final SessionManager _sessions;
  final ApiClient _api;
  final String conversationId;
  final String myDeviceId;
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

  Future<void> _markRead() async {
    await (_db.update(_db.conversations)
          ..where((c) => c.id.equals(conversationId)))
        .write(const ConversationsCompanion(unreadCount: Value(0)));
  }

  Future<void> sendMessage(String text) => _send(text, 'text');

  Future<void> sendAttachment(String name, Uint8List bytes) =>
      _send(Attachment(name: name, bytes: bytes).encode(), 'file');

  Future<void> _send(String text, String type) async {
    if (text.trim().isEmpty) return;
    final id = _uuid.v4();
    final now = DateTime.now();
    await _db.transaction(() async {
      await _db
          .into(_db.messages)
          .insert(
            MessagesCompanion.insert(
              id: id,
              conversationId: conversationId,
              senderId: myDeviceId,
              body: Value(text),
              type: Value(type),
              status: const Value('sending'),
              createdAt: now,
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
    if (message.senderId != myDeviceId ||
        message.conversationId != conversationId ||
        (message.status != 'failed' && message.status != 'sending')) {
      return;
    }
    await _status(messageId, 'sending');
    _auditRecipientMissing = false;
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
              )).where((id) => id != myDeviceId).toList();
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
