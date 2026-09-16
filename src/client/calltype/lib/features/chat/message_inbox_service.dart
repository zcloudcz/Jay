import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/crypto/session_manager.dart';
import '../../core/network/api_client.dart';
import '../../core/storage/database.dart';
import 'attachment.dart';

/// One queue per device database protects ratchet updates across chats and inbox.
class MessageProcessingQueue {
  static final _queues = Expando<MessageProcessingQueue>();
  static MessageProcessingQueue forDatabase(AppDatabase db) =>
      _queues[db] ??= MessageProcessingQueue();
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

/// Persists incoming messages before acknowledging their server queue entries.
class MessageInboxService {
  MessageInboxService({
    required AppDatabase database,
    required SessionManager sessionManager,
    required Stream<Map<String, dynamic>> incomingMessages,
    ApiClient? apiClient,
    Future<void> Function(String senderId, String messageId)? acknowledge,
  }) : _db = database,
       _sessionManager = sessionManager,
       _incoming = incomingMessages,

       _acknowledge = acknowledge;

  final AppDatabase _db;
  final SessionManager _sessionManager;
  final Stream<Map<String, dynamic>> _incoming;

  final Future<void> Function(String, String)? _acknowledge;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  final _persisted = StreamController<Message>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  Stream<Message> get persistedMessages => _persisted.stream;
  Stream<Object> get errors => _errors.stream;
  Future<void> _pending = Future.value();

  void start() {
    _subscription ??= _incoming.listen((data) {
      _pending = MessageProcessingQueue.forDatabase(
        _db,
      ).run(() => _handleIncoming(data));
    });
  }

  Future<void> _handleIncoming(Map<String, dynamic> data) async {
    try {
      final senderId = data['senderId'] as String?;
      final messageId = data['messageId'] as String?;
      final groupId = data['groupId'] as String?;
      if (senderId == null ||
          senderId.isEmpty ||
          messageId == null ||
          messageId.isEmpty) {
        throw const FormatException('Missing message identity');
      }
      final conversationId = groupId ?? senderId;
      final existing = await (_db.select(
        _db.messages,
      )..where((m) => m.id.equals(messageId))).getSingleOrNull();
      if (existing != null) {
        if (existing.senderId != senderId ||
            existing.conversationId != conversationId) {
          throw const FormatException('Conflicting message identity');
        }
        await _acknowledge?.call(senderId, messageId);
        return;
      }
      // Membership was authorized by the relay when it accepted the message.
      // Current membership can differ after an offline recipient reconnects.
      late Message inserted;
      await _db.transaction(() async {
        final envelope = utf8.decode(
          base64Decode(data['encryptedBody'] as String),
        );
        final plaintext = await _sessionManager.decryptMessage(
          senderId,
          envelope,
          deferPreKeyCleanup: true,
        );
        final payload = jsonDecode(plaintext) as Map<String, dynamic>;
        if (payload['v'] != 1 ||
            payload['id'] != messageId ||
            payload['groupId'] != groupId ||
            payload['body'] is! String) {
          throw const FormatException(
            'Encrypted message context does not match delivery',
          );
        }
        final type = payload['type'] as String? ?? 'text';
        if (type != 'text' && type != 'file') {
          throw const FormatException('Unsupported message type');
        }
        if (type == 'file') Attachment.decode(payload['body'] as String);
        final now = DateTime.now();
        final createdAt =
            DateTime.tryParse(payload['createdAt'] as String? ?? '') ?? now;
        final conversation = await (_db.select(
          _db.conversations,
        )..where((c) => c.id.equals(conversationId))).getSingleOrNull();
        if (conversation == null) {
          await _db
              .into(_db.conversations)
              .insert(
                ConversationsCompanion.insert(
                  id: conversationId,
                  type: groupId == null ? 'direct' : 'group',
                  title: Value(
                    groupId == null ? null : payload['groupName'] as String?,
                  ),
                ),
              );
        } else if (conversation.type !=
            (groupId == null ? 'direct' : 'group')) {
          throw const FormatException('Conflicting conversation type');
        }
        await _db
            .into(_db.messages)
            .insert(
              MessagesCompanion.insert(
                id: messageId,
                conversationId: conversationId,
                senderId: senderId,
                body: Value(payload['body'] as String),
                type: Value(type),
                status: const Value('delivered'),
                createdAt: createdAt,
                receivedAt: Value(now),
              ),
            );
        await (_db.update(
          _db.conversations,
        )..where((c) => c.id.equals(conversationId))).write(
          ConversationsCompanion(
            lastMessageAt: Value(now),
            unreadCount: Value((conversation?.unreadCount ?? 0) + 1),
          ),
        );
        inserted = await (_db.select(
          _db.messages,
        )..where((m) => m.id.equals(messageId))).getSingle();
      });
      await _sessionManager.finalizePreKeyCleanup();
      _persisted.add(inserted);
      await _acknowledge?.call(senderId, messageId);
    } catch (error) {
      // Leave failures queued on the server; never report corrupt ciphertext as delivered.
      _errors.add(error);
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    await _pending;
    await _persisted.close();
    await _errors.close();
  }
}
