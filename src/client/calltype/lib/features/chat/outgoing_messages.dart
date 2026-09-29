/// The ONE outgoing-message API of the app (contracts K4 = M §4.5 with the
/// K4 changes). Stream M implements it (M02 `MessageSender`); N (reply from
/// a notification, mark read), M2 (media), G (`profile`, `group-update`)
/// and D (`device-list`) only call it. `outgoing_message_service.dart` (N)
/// and `ControlMessageSender` (G) intentionally do not exist.
library;

/// Quote of an earlier message (`replyTo` on the wire, M §4.1).
class ReplyRef {
  const ReplyRef({
    required this.id,
    required this.senderId,
    required this.preview,
  });

  final String id;
  final String senderId;

  /// At most 100 characters of the quoted text.
  final String preview;
}

abstract class OutgoingMessages {
  /// Stores a `sending` row, encrypts, sends; returns the message id.
  /// Offline → the row stays `sending` and goes out after the reconnect.
  Future<String> sendContent(
    String conversationId, {
    required String type,
    required String body,
    ReplyRef? replyTo,
    bool forwarded = false,
  });

  Future<String> sendText(
    String conversationId,
    String text, {
    ReplyRef? replyTo,
  });

  /// A control message: quiet (no push), no row in `Messages`, `ctl: true`
  /// added automatically. [fields] go to the TOP level of the envelope
  /// (M `receipt`: `kind`, `ref`); [body] is a JSON string (G `profile` /
  /// `group-update`, D `device-list`). [recipients] null = every member
  /// (plus the auditor); otherwise only these — in a business group the
  /// auditor is ALWAYS added (KB2). [durable] false = one attempt, errors
  /// are thrown; true = queued and retried like content.
  Future<void> sendControl(
    String conversationId,
    String type, {
    String body = '',
    Map<String, Object?> fields = const {},
    List<String>? recipients,
    bool durable = true,
  });

  Future<void> retry(String messageId);

  /// unreadCount = 0 and, once M04 exists, a `receipt kind: read` (N).
  Future<void> markConversationRead(String conversationId);
}

/// Provided by main.dart until M02 replaces it.
///
/// WHY not an adapter over today's sending: that logic lives inside the
/// route-scoped ChatController (outbox rows, per-recipient encryption, the
/// KB1/KB2/P1 error flags). Pulling it out IS M02's work package; a second
/// copy here would be a parallel sending path M throws away, in the hottest
/// file of wave 1. Callers coded against this interface fail loudly in
/// development instead of sending half-correct messages.
class UnimplementedOutgoingMessages implements OutgoingMessages {
  const UnimplementedOutgoingMessages();

  static Never _todo() =>
      throw UnimplementedError('OutgoingMessages is implemented by stream M');

  @override
  Future<String> sendContent(
    String conversationId, {
    required String type,
    required String body,
    ReplyRef? replyTo,
    bool forwarded = false,
  }) async => _todo();

  @override
  Future<String> sendText(
    String conversationId,
    String text, {
    ReplyRef? replyTo,
  }) async => _todo();

  @override
  Future<void> sendControl(
    String conversationId,
    String type, {
    String body = '',
    Map<String, Object?> fields = const {},
    List<String>? recipients,
    bool durable = true,
  }) async => _todo();

  @override
  Future<void> retry(String messageId) async => _todo();

  @override
  Future<void> markConversationRead(String conversationId) async => _todo();
}
