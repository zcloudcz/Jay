import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../core/crypto/key_manager.dart';
import '../../core/crypto/session_manager.dart';
import '../../core/network/api_client.dart';
import '../../core/network/signalr_client.dart';
import '../../core/storage/database.dart';

/// Manages state for a single conversation — loads messages from DB,
/// listens for incoming messages via SignalR, and sends new messages.
///
/// Bridges the local database (source of truth for message history) with
/// the real-time SignalR transport. The flow is:
///   1. User sends message → store locally with status 'sending'
///   2. Encrypt via [SessionManager] → send via SignalR
///   3. Update status to 'sent' on success / 'failed' on error
///   4. Incoming message via SignalR → decrypt → store in DB → reload list
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
    required KeyManager keyManager,
    required ApiClient apiClient,
    required this.conversationId,
    required this.myDeviceId,
  })  : _db = database,
        _signalR = signalRClient,
        _sessionManager = sessionManager,
        _keyManager = keyManager,
        _apiClient = apiClient {
    _loadMessages();
    _listenForIncoming();
  }

  final AppDatabase _db;
  final SignalRClient _signalR;
  final SessionManager _sessionManager;
  final KeyManager _keyManager;
  final ApiClient _apiClient;

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

  /// Subscribes to the SignalR message stream and processes incoming messages.
  ///
  /// Only processes messages that belong to this conversation. Incoming
  /// encrypted bodies are decrypted via [SessionManager] before storage.
  /// If decryption fails (no session, tampered data), the encrypted body
  /// is stored as-is with a "[encrypted]" prefix so the user sees something
  /// rather than nothing.
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

      final encryptedBody = data['encryptedBody']?.toString() ?? '';

      // Attempt to decrypt the incoming message body.
      // Falls back to storing the raw encrypted data if decryption fails —
      // this can happen if the session was lost (e.g. app reinstall) or
      // if the message was corrupted in transit.
      String decryptedBody;
      try {
        final encryptedBytes = Uint8List.fromList(base64Decode(encryptedBody));
        decryptedBody = await _sessionManager.decryptMessage(
          senderId,
          encryptedBytes,
        );
      } catch (_) {
        // Decryption failed — store a placeholder. The user can see that
        // a message arrived but can't read it. A re-keying flow (future
        // feature) would resolve this by re-establishing the session.
        decryptedBody = '[encrypted] $encryptedBody';
      }

      final message = MessagesCompanion.insert(
        id: _uuid.v4(),
        conversationId: conversationId,
        senderId: senderId,
        body: Value(decryptedBody),
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

      // Encrypt the message with the session's current chain key.
      final encrypted = await _sessionManager.encryptMessage(
        conversationId,
        text,
      );

      // Send the encrypted bytes as base64 — the server treats this as
      // an opaque blob and never attempts to parse or decrypt it.
      final encryptedBase64 = base64Encode(encrypted);
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
    final myPrivateKey = await _keyManager.getPrivateIdentityKey();

    await _sessionManager.initializeSession(
      peerDeviceId,
      keyBundle,
      myPrivateKey,
    );
  }

  @override
  void dispose() {
    _messageSubscription?.cancel();
    super.dispose();
  }
}
