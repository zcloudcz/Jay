import 'dart:async';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../../core/storage/database.dart';

/// Manages the list of all conversations for the main chat list screen.
///
/// Queries the local database for conversations ordered by most recent
/// message timestamp, matching the standard messaging app sort order
/// (most active chat at the top).
///
/// Uses [ChangeNotifier] so the chat list screen rebuilds when
/// conversations are added or the list is refreshed.
class ChatListController extends ChangeNotifier {
  ChatListController({required AppDatabase database}) : _db = database;

  final AppDatabase _db;
  StreamSubscription<List<Conversation>>? _subscription;
  bool _disposed = false;
  String? error;

  /// All conversations, ordered by lastMessageAt descending.
  List<Conversation> get conversations => List.unmodifiable(_conversations);
  List<Conversation> _conversations = [];

  /// Loads all conversations from the database.
  ///
  /// Orders by lastMessageAt descending (most recent first) with nulls
  /// last — new conversations without messages sort to the bottom.
  Future<void> loadConversations() async {
    final query = _db.select(_db.conversations)
      ..orderBy([
        (c) =>
            OrderingTerm(expression: c.lastMessageAt, mode: OrderingMode.desc),
      ]);

    _conversations = await query.get();
    if (_disposed) return;
    _subscription ??= query.watch().listen(
      (rows) {
        if (_disposed) return;
        _conversations = rows;
        error = null;
        notifyListeners();
      },
      onError: (Object failure) {
        if (_disposed) return;
        error = failure.toString();
        notifyListeners();
      },
    );
    notifyListeners();
  }

  /// Creates a direct conversation with a specific device if one doesn't
  /// already exist.
  ///
  /// For direct chats, the conversation ID is the peer's device UUID.
  /// This convention simplifies message routing — when a message arrives
  /// from a device, we know exactly which conversation it belongs to
  /// without an extra lookup.
  ///
  /// Returns the conversation ID (existing or newly created).
  Future<String> createDirectConversation(String deviceId) async {
    // Check if a conversation with this device already exists.
    final existing = await (_db.select(
      _db.conversations,
    )..where((c) => c.id.equals(deviceId))).getSingleOrNull();

    if (existing != null) return existing.id;

    // Create a new direct conversation. The ID is the peer's deviceId
    // so incoming messages from that device automatically map to this
    // conversation without any extra mapping table.
    final companion = ConversationsCompanion.insert(
      id: deviceId,
      type: 'direct',
    );

    await _db.into(_db.conversations).insert(companion);
    await loadConversations();

    return deviceId;
  }

  @override
  void dispose() {
    _disposed = true;
    _subscription?.cancel();
    super.dispose();
  }
}
