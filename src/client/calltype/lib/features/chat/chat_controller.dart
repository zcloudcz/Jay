import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../core/crypto/session_manager.dart';
import '../../core/network/api_client.dart';
import '../../core/network/signalr_client.dart';
import '../../core/storage/database.dart';
import 'message_inbox_service.dart';

/// Manages state for a single conversation — loads messages from DB and
/// sends new messages.
///
/// The flow is:
///   1. User sends message → store locally with status 'sending'
///   2. Encrypt via [SessionManager] → send via SignalR
///   3. Update status to 'sent' on success / 'failed' on error
///   4. Incoming messages are decrypted + persisted by the app-wide
///      [MessageInboxService] (so nothing is lost while this screen is
///      closed); this controller only listens to its [persistedMessages]
///      stream and reloads the visible list.
///
/// Session establishment happens lazily on first send: if no E2E session
/// exists with the peer, we fetch their key bundle from the API and perform
/// X3DH before encrypting. This avoids pre-establishing sessions with
/// contacts we never message.
///
/// Uses [ChangeNotifier] so the chat screen rebuilds reactively when
/// messages change. The controller is scoped to a single conversation
/// and should be disposed when the user navigates away.
class ChatController extends ChangeNotifier {
  ChatController({
    required AppDatabase database,
    required SignalRClient signalRClient,
    required SessionManager sessionManager,
    required MessageInboxService inbox,
    required ApiClient apiClient,
    required this.conversationId,
    required this.myDeviceId,
  })  : _db = database,
        _signalR = signalRClient,
        _sessionManager = sessionManager,
        _apiClient = apiClient {
    _loadMessages();
    _listenForIncoming(inbox);
    // Opening the chat means the user is reading it — clear the unread
    // badge that the inbox service has been incrementing.
    _markConversationRead();
  }

  final AppDatabase _db;
  final SignalRClient _signalR;
  final SessionManager _sessionManager;
  final ApiClient _apiClient;

  /// The conversation this controller manages.
  final String conversationId;

  /// This device's UUID — used to determine message direction (mine vs. theirs)
  /// and as the senderId for outgoing messages.
  final String myDeviceId;

  StreamSubscription<Message>? _messageSubscription;

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

  /// Subscribes to the inbox's persisted-message stream and reloads the
  /// visible list when a message for THIS conversation lands in the DB.
  ///
  /// Decryption and persistence already happened in [MessageInboxService] —
  /// re-doing either here would double-process every message.
  void _listenForIncoming(MessageInboxService inbox) {
    _messageSubscription = inbox.persistedMessages.listen((message) async {
      // Other conversations have their own ChatController instances.
      if (message.conversationId != conversationId) return;

      await _loadMessages();
      // The user is looking at this chat, so the message the inbox just
      // counted as unread has effectively been read already.
      await _markConversationRead();
    });
  }

  /// Clears the unread badge for this conversation.
  Future<void> _markConversationRead() async {
    await (_db.update(_db.conversations)
          ..where((c) => c.id.equals(conversationId)))
        .write(const ConversationsCompanion(unreadCount: Value(0)));
  }

  /// Sends a text message in this conversation.
  ///
  /// The message is stored locally first (optimistic insert with status
  /// 'sending'), then encrypted via [SessionManager] and sent via SignalR.
  /// On success the status updates to 'sent'; on failure it becomes 'failed'
  /// so the UI can show a retry option.
  ///
  /// If no E2E session exists with the peer, automatically fetches their
  /// key bundle from the API and establishes a session via X3DH before
  /// encrypting. This lazy initialization avoids wasting resources on
  /// sessions that may never be used.
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
      // Ensure we have an E2E session with the peer. If not, fetch their
      // key bundle and perform X3DH to establish one.
      await _ensureSession(conversationId);

      // Encrypt the message — returns a JSON envelope with the Double
      // Ratchet header and ciphertext.
      final envelope = await _sessionManager.encryptMessage(
        conversationId,
        text,
      );

      // Send the envelope as base64(UTF-8 JSON) — the server treats this
      // as an opaque blob and never attempts to parse or decrypt it.
      final encryptedBase64 = base64Encode(utf8.encode(envelope));
      await _signalR.sendMessage(conversationId, encryptedBase64);

      // Network send succeeded — update status to 'sent'.
      await (_db.update(_db.messages)
            ..where((m) => m.id.equals(messageId)))
          .write(const MessagesCompanion(status: Value('sent')));
    } catch (_) {
      // Encryption or network failure — mark as 'failed' so the UI
      // can offer retry.
      await (_db.update(_db.messages)
            ..where((m) => m.id.equals(messageId)))
          .write(const MessagesCompanion(status: Value('failed')));
    }

    await _loadMessages();
  }

  /// Ensures an E2E session exists with the given peer device.
  ///
  /// If no session exists, fetches the peer's X3DH key bundle from the
  /// server API and initializes a new session. This is the "lazy X3DH"
  /// pattern — sessions are established on first message, not on contact add.
  Future<void> _ensureSession(String peerDeviceId) async {
    if (await _sessionManager.hasSession(peerDeviceId)) return;

    // Fetch peer's key bundle: identity key + signed pre-key + OTK.
    // The server consumes the OTK atomically — subsequent fetches for
    // the same peer return a different OTK (or none if depleted).
    final keyBundle = await _apiClient.getKeyBundle(peerDeviceId);

    await _sessionManager.initiateSession(peerDeviceId, keyBundle);
  }

  @override
  void dispose() {
    _messageSubscription?.cancel();
    super.dispose();
  }
}
