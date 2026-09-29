/// Wire vocabulary of the plaintext INSIDE the Double Ratchet envelope
/// (contracts §3). Shared by the app, `calltype_bot` and `jay_archiver` so
/// every receiver classifies a payload the same way.
///
/// X0 skeleton: constants and the classification helpers every receiver
/// needs for the tolerance rules (K1/K2). The typed control messages
/// (`ReceiptMessage`, `ReactionMessage`, …), their parsers and builders are
/// added here by stream M (M01) — keep this file free of Flutter imports,
/// the bots must be able to import it.
library;

/// Envelope field marking a control message (K1). Senders of every control
/// type set `"ctl": true`, so a receiver that does not know the type yet can
/// still tell "silently acknowledge" from "content I cannot render".
const ctlField = 'ctl';

/// Message `type` values of the wire format.
abstract final class MessageTypes {
  // Content — stored as a row in Messages, bump unreadCount (except
  // call-event), reach `persistedMessages`.
  static const text = 'text';
  static const file = 'file';
  static const callEvent = 'call-event';
  static const media = 'media';

  // Control (`ctl: true`) — never create a conversation, never bump
  // unreadCount / lastMessageAt, never reach `persistedMessages`.
  static const receipt = 'receipt';
  static const reaction = 'reaction';
  static const edit = 'edit';
  static const delete = 'delete';
  static const profile = 'profile';
  static const groupUpdate = 'group-update';
  static const deviceList = 'device-list';
  static const deviceListRequest = 'device-list-request';
  static const sync = 'sync';
  static const provision = 'provision';

  /// LOCAL only (G): a group/identity event line written by this device.
  /// Never sent; a received payload with this type is treated as unknown.
  static const system = 'system';
}

/// Control types known to this version. A received payload of one of these
/// types is control even if an older sender forgot `ctl`.
const knownControlTypes = {
  MessageTypes.receipt,
  MessageTypes.reaction,
  MessageTypes.edit,
  MessageTypes.delete,
  MessageTypes.profile,
  MessageTypes.groupUpdate,
  MessageTypes.deviceList,
  MessageTypes.deviceListRequest,
  MessageTypes.sync,
  MessageTypes.provision,
};

/// True for a control message: a known control type, or any payload that
/// declares `ctl: true` (an unknown future control type, K1).
bool isControlPayload(Map<String, dynamic> payload) =>
    payload[ctlField] == true ||
    knownControlTypes.contains(payload['type']);

/// The payload's `type`, defaulting to `text` like every receiver has done
/// since v1 (early senders omitted it). A present but non-string or empty
/// type is malformed ([FormatException]) — it must not be mistaken for text.
String payloadType(Map<String, dynamic> payload) {
  final type = payload['type'];
  if (type == null) return MessageTypes.text;
  if (type is! String || type.isEmpty) {
    throw const FormatException('Message type must be a non-empty string');
  }
  return type;
}
