import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/crypto/session_manager.dart';
import '../../core/storage/database.dart';

/// App-wide inbox: receives EVERY incoming SignalR message, decrypts it,
/// and persists it to the local database — regardless of which screen
/// (if any) is currently open.
///
/// This must be a single, always-running service rather than per-chat
/// logic: the server deletes queued messages the moment they are delivered
/// (store-and-forward), so a message that arrives while its chat screen is
/// closed would otherwise be lost forever. Route-scoped controllers
/// ([ChatController]) only RENDER what this service has persisted.
///
/// Responsibilities per message:
///   1. Ensure the conversation row exists (created on first contact —
///      the sender may be someone we've never messaged).
///   2. Decrypt via [SessionManager] (which also establishes brand-new
///      sessions from pre-key messages).
///   3. Insert the message row and bump the conversation's lastMessageAt
///      + unreadCount.
///   4. Emit the persisted row on [persistedMessages] so open screens can
///      react without re-implementing any of the above.
class MessageInboxService {
  MessageInboxService({
    required AppDatabase database,
    required SessionManager sessionManager,
    required Stream<Map<String, dynamic>> incomingMessages,
  })  : _db = database,
        _sessionManager = sessionManager,
        _incoming = incomingMessages;

  final AppDatabase _db;
  final SessionManager _sessionManager;
  final Stream<Map<String, dynamic>> _incoming;

  StreamSubscription<Map<String, dynamic>>? _subscription;

  final _persisted = StreamController<Message>.broadcast();

  /// Fires after an incoming message has been decrypted and written to the
  /// database. Chat screens listen filtered by conversationId; the chat
  /// list can listen unfiltered to refresh ordering/unread badges.
  Stream<Message> get persistedMessages => _persisted.stream;

  static const _uuid = Uuid();

  /// Starts consuming the incoming message stream. Call once at app startup.
  void start() {
    // Errors are contained per message inside _handleIncoming — one
    // malformed payload must not kill the subscription for all future
    // messages.
    _subscription ??= _incoming.listen(_handleIncoming);
  }

  Future<void> _handleIncoming(Map<String, dynamic> data) async {
    try {
      final senderId = data['senderId']?.toString();
      if (senderId == null) return;

      // Direct chats use the peer's deviceId as the conversation ID;
      // group messages carry an explicit groupId.
      final groupId = data['groupId']?.toString();
      final conversationId = groupId ?? senderId;

      await _ensureConversation(conversationId, isGroup: groupId != null);

      // Decrypt; fall back to a marker the UI can recognize when the
      // session is broken (app reinstall, corrupted payload). The raw
      // body is kept so nothing is silently dropped.
      final encryptedBody = data['encryptedBody']?.toString() ?? '';
      String body;
      try {
        final envelopeJson = utf8.decode(base64Decode(encryptedBody));
        body = await _sessionManager.decryptMessage(senderId, envelopeJson);
      } catch (_) {
        body = '[encrypted] $encryptedBody';
      }

      final now = DateTime.now();
      final message = MessagesCompanion.insert(
        id: _uuid.v4(),
        conversationId: conversationId,
        senderId: senderId,
        body: Value(body),
        status: const Value('delivered'),
        createdAt: now,
        receivedAt: Value(now),
      );
      await _db.into(_db.messages).insert(message);

      await _bumpConversation(conversationId, now);

      final inserted = await (_db.select(_db.messages)
            ..where((m) => m.id.equals(message.id.value)))
          .getSingle();
      _persisted.add(inserted);
    } catch (_) {
      // Swallow per-message failures — see start(). A logging hook can be
      // added once the app has a client-side logging strategy.
    }
  }

  /// Creates the conversation row if this is the first message exchanged
  /// with the peer/group. Without this, messages would persist but never
  /// show up in the chat list.
  Future<void> _ensureConversation(String conversationId,
      {required bool isGroup}) async {
    final existing = await (_db.select(_db.conversations)
          ..where((c) => c.id.equals(conversationId)))
        .getSingleOrNull();
    if (existing != null) return;

    await _db.into(_db.conversations).insert(
          ConversationsCompanion.insert(
            id: conversationId,
            type: isGroup ? 'group' : 'direct',
          ),
        );
  }

  /// Updates the conversation's sort timestamp and increments the unread
  /// counter. Read-then-write instead of a SQL expression for clarity —
  /// chat message volume makes the extra query irrelevant.
  Future<void> _bumpConversation(String conversationId, DateTime when) async {
    final row = await (_db.select(_db.conversations)
          ..where((c) => c.id.equals(conversationId)))
        .getSingle();

    await (_db.update(_db.conversations)
          ..where((c) => c.id.equals(conversationId)))
        .write(ConversationsCompanion(
      lastMessageAt: Value(when),
      unreadCount: Value(row.unreadCount + 1),
    ));
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    await _persisted.close();
  }
}
