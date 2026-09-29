import 'package:calltype_core/messaging/control_messages.dart';

import '../../../core/storage/database.dart';

/// Everything a handler may know about one decrypted incoming message
/// (contracts K3 = M §4.4 + D's `fromOwnDevice` / `copyWith`).
class InboundContext {
  InboundContext({
    required this.db,
    required this.messageId,
    required this.senderId,
    required this.conversationId,
    required this.myDeviceId,
    required this.groupId,
    required this.payload,
    required this.serverCreatedAt,
    required this.now,
    this.fromOwnDevice = false,
  });

  final AppDatabase db;
  final String messageId;
  final String senderId;

  /// `groupId ?? DeviceDirectory.directConversationFor(senderId)`.
  final String conversationId;
  final String myDeviceId;
  final String? groupId;

  /// The already validated envelope (`v == 1`, `id`, `groupId` match the
  /// delivery, `body is String`).
  final Map<String, dynamic> payload;

  /// `createdAt` of the hub delivery (server clock).
  final DateTime serverCreatedAt;

  /// Local receive time; one value per message so every row a handler
  /// writes carries the same timestamp.
  final DateTime now;

  /// True for content unpacked from a `sync` message of one of my own
  /// devices (D, wave 2): content handlers then store it as MY message
  /// (`status: 'sent'`) and do not bump unreadCount.
  final bool fromOwnDevice;

  /// Wire type (defaults to `text`, see [payloadType]).
  String get type => payloadType(payload);

  /// Always a string — validated before any handler runs.
  String get body => payload['body'] as String;

  /// The SENDER's clock (`payload.createdAt`), falling back to [now] for
  /// early senders that omitted it. Display order and LWW rules use this.
  DateTime get senderCreatedAt =>
      DateTime.tryParse(payload['createdAt'] as String? ?? '') ?? now;

  /// Re-entrant dispatch (D `sync`): the nested content keeps the delivery
  /// identity but may target another conversation / carry another payload.
  InboundContext copyWith({
    String? conversationId,
    bool? fromOwnDevice,
    Map<String, dynamic>? payload,
  }) => InboundContext(
    db: db,
    messageId: messageId,
    senderId: senderId,
    conversationId: conversationId ?? this.conversationId,
    myDeviceId: myDeviceId,
    groupId: groupId,
    payload: payload ?? this.payload,
    serverCreatedAt: serverCreatedAt,
    now: now,
    fromOwnDevice: fromOwnDevice ?? this.fromOwnDevice,
  );
}

/// What processing one message produced. The inbox acknowledges the
/// message after the transaction commits in every case.
sealed class InboundResult {
  const InboundResult();
}

/// A content row was stored → emitted on `persistedMessages` (N notifies).
class StoredContent extends InboundResult {
  const StoredContent(this.message);
  final Message message;
}

/// A control message changed local state → emitted on `controlEvents`.
class Applied extends InboundResult {
  const Applied(this.event);
  final ControlEvent event;
}

/// Nothing to do (unknown control type, blocked sender, stale edit …).
class Ignored extends InboundResult {
  const Ignored();
}

/// Handler for one wire `type`.
///
/// Runs INSIDE the inbox transaction, after decryption, so its writes and
/// the ratchet advance commit (or roll back) together. Therefore it must
/// never call the network — a slow request would hold the transaction and
/// every other incoming message; defer network work (G's `pending_control:`
/// pattern) and do it after the commit.
///
/// Throw [FormatException] for a malformed message: the inbox rolls back
/// just this handler's writes, records the id in `InboundLog`, ACKs and
/// drops it — a message that decrypted fine will not get better by being
/// redelivered for 30 days. Any other exception rolls back everything and
/// leaves the message unacknowledged on the server (retried later).
abstract class InboundTypeHandler {
  Future<InboundResult> handle(InboundContext ctx);
}

/// Emitted for an [Applied] control message (UI refresh; N in P2).
class ControlEvent {
  const ControlEvent({
    required this.type,
    required this.conversationId,
    required this.senderId,
    this.refs = const [],
  });

  final String type;
  final String conversationId;
  final String senderId;

  /// Ids of the messages the control message refers to.
  final List<String> refs;
}
