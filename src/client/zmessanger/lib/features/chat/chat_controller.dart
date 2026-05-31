import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../core/network/signalr_client.dart';
import '../../core/storage/database.dart';

/// Manages state for a single conversation — loads messages from DB,
/// listens for incoming messages via SignalR, and sends new messages.
///
/// Bridges the local database (source of truth for message history) with
/// the real-time SignalR transport. The flow is:
///   1. User sends message → store locally with status 'sending'
///   2. Send via SignalR → update status to 'sent' on success / 'failed' on error
///   3. Incoming message via SignalR → store in DB → reload list
///
/// Uses [ChangeNotifier] so the chat screen rebuilds reactively when
/// messages change. The controller is scoped to a single conversation
/// and should be disposed when the user navigates away.
class ChatController extends ChangeNotifier {
  ChatController({
    required AppDatabase database,
    required SignalRClient signalRClient,
    required this.conversationId,
    required this.myDeviceId,
  })  : _db = database,
        _signalR = signalRClient {
    _loadMessages();
    _listenForIncoming();
  }

  final AppDatabase _db;
  final SignalRClient _signalR;

  /// The conversation this controller manages.
  final String conversationId;

  /// This device's UUID — used to determine message direction (mine vs. theirs)
  /// and as the senderId for outgoing messages.
  final String myDeviceId;

  StreamSubscription<Map<String, dynamic>>? _messageSubscription;

  /// Current message list, ordered newest-first (for reversed ListView).
  List<Message> get messages => List.unmodifiable(_messages);
  List<Message> _messages = [];

  static const _uuid = Uuid();

  /// Loads all messages for this conversation from the local database.
  ///
  /// Ordered by createdAt descending (newest first) because the chat UI
  /// uses a reversed ListView that renders from the bottom up.
  Future<void> _loadMessages() async {
    final query = _db.select(_db.messages)
      ..where((m) => m.conversationId.equals(conversationId))
      ..orderBy([
        (m) => OrderingTerm(
              expression: m.createdAt,
              mode: OrderingMode.desc,
            ),
      ]);

    _messages = await query.get();
    notifyListeners();
  }

  /// Subscribes to the SignalR message stream and stores incoming messages.
  ///
  /// Only processes messages that belong to this conversation. The
  /// conversation matching logic uses the senderId — for direct chats,
  /// the conversationId IS the peer's deviceId. For group chats, the
  /// server includes a groupId field.
  void _listenForIncoming() {
    _messageSubscription = _signalR.onMessage.listen((data) async {
      final senderId = data['senderId']?.toString();
      if (senderId == null) return;

      // For direct chats, the conversationId is the peer's deviceId.
      // For group chats, it would be the groupId from the payload.
      final incomingConversationId =
          data['groupId']?.toString() ?? senderId;

      // Only process messages for THIS conversation — other conversations
      // have their own ChatController instances.
      if (incomingConversationId != conversationId) return;

      // TODO: Decrypt encryptedBody using SessionManager once libsignal
      // is integrated. For now, store the encrypted body as-is.
      final encryptedBody = data['encryptedBody']?.toString() ?? '';

      final message = MessagesCompanion.insert(
        id: _uuid.v4(),
        conversationId: conversationId,
        senderId: senderId,
        body: Value(encryptedBody),
        status: const Value('delivered'),
        createdAt: DateTime.now(),
        receivedAt: Value(DateTime.now()),
      );

      await _db.into(_db.messages).insert(message);

      // Update the conversation's last message timestamp so the chat list
      // sorts correctly without a separate refresh.
      await (_db.update(_db.conversations)
            ..where((c) => c.id.equals(conversationId)))
          .write(ConversationsCompanion(
        lastMessageAt: Value(DateTime.now()),
        // Increment unread count — the chat list screen resets it when opened.
        unreadCount: const Value(1),
      ));

      await _loadMessages();
    });
  }

  /// Sends a text message in this conversation.
  ///
  /// The message is stored locally first (optimistic insert with status
  /// 'sending'), then sent via SignalR. On success the status updates to
  /// 'sent'; on failure it becomes 'failed' so the UI can show a retry option.
  ///
  /// TODO: Encrypt the message body via SessionManager before sending.
  /// Currently sends plaintext — this is acceptable only during development
  /// before the E2E encryption pipeline is complete.
  Future<void> sendMessage(String text) async {
    final messageId = _uuid.v4();
    final now = DateTime.now();

    // Optimistic local insert — the message appears immediately in the UI
    // with a clock icon (status='sending') while the network call happens.
    final companion = MessagesCompanion.insert(
      id: messageId,
      conversationId: conversationId,
      senderId: myDeviceId,
      body: Value(text),
      status: const Value('sending'),
      createdAt: now,
    );

    await _db.into(_db.messages).insert(companion);

    // Update conversation timestamp so it bubbles to the top of the chat list.
    await (_db.update(_db.conversations)
          ..where((c) => c.id.equals(conversationId)))
        .write(ConversationsCompanion(lastMessageAt: Value(now)));

    await _loadMessages();

    try {
      // TODO: Replace plaintext with encrypted body from SessionManager.
      // For now, send the raw text as base64 to match the server's expected
      // format without actual encryption.
      await _signalR.sendMessage(conversationId, text);

      // Network send succeeded — update status to 'sent'.
      await (_db.update(_db.messages)
            ..where((m) => m.id.equals(messageId)))
          .write(const MessagesCompanion(status: Value('sent')));
    } catch (_) {
      // Network failure — mark as 'failed' so the UI can offer retry.
      await (_db.update(_db.messages)
            ..where((m) => m.id.equals(messageId)))
          .write(const MessagesCompanion(status: Value('failed')));
    }

    await _loadMessages();
  }

  @override
  void dispose() {
    _messageSubscription?.cancel();
    super.dispose();
  }
}
