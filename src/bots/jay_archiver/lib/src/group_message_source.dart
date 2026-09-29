import 'dart:async';
import 'dart:convert';

import 'package:calltype_core/attachments/media_ref.dart';
import 'package:calltype_core/messaging/control_messages.dart';
import 'package:calltype_core/network/signalr_client.dart';
import 'package:calltype_core/crypto/session_manager.dart';
import 'package:crypto/crypto.dart' as crypto;

/// One archivable event: everything the archive write API (KB3) needs, and
/// nothing else. In particular there is no plaintext field — the source
/// computes [contentHashHex]/[sizeBytes] itself and discards the plaintext
/// immediately (KB3: "plaintext is never stored, never logged").
class IncomingGroupMessage {
  IncomingGroupMessage({
    required this.messageId,
    required this.groupId,
    required this.senderId,
    required this.sentAt,
    required this.kind,
    required this.sizeBytes,
    required this.contentHashHex,
    this.detailsJson,
  });

  final String messageId;
  final String groupId;
  final String senderId;
  final DateTime sentAt;

  /// "text" | "attachment" | "call-metadata" | "group-event" | "edit" |
  /// "delete" | "reaction" | "other" (contracts §3, K2).
  final String kind;
  final int sizeBytes;

  /// Lowercase hex SHA-256 of the plaintext (text / attachment /
  /// group-event) or of [detailsJson] (call-metadata, edit, delete,
  /// reaction, other) — see ArchiveRecordRequest.ContentHash.
  final String contentHashHex;

  /// Sent verbatim as `details`; the server re-hashes it, which binds it to
  /// the hash chain. H1 call-metadata: the call-event body (a call is
  /// metadata, kept readable). edit/delete/reaction: `{"ref","bodyHash"}`
  /// (M §4.2). other: `{"type"}` (K2). Null for every other kind.
  final String? detailsJson;
}

/// The seam between "how we get plaintext to hash" and "what we do with the
/// metadata". Today's implementation ([SignalGroupMessageSource]) decrypts
/// the per-recipient Signal-style fan-out (K01/KB2). Step 2 (MLS, plan §6)
/// swaps this for an implementation that decrypts the group's shared
/// ciphertext instead — nothing above this interface needs to change.
abstract class GroupMessageSource {
  /// Emits one event per successfully decrypted, well-formed group message.
  /// A message that fails to decrypt or parse is NOT emitted here — it is
  /// logged (by id only) and left for the server to redeliver.
  Stream<IncomingGroupMessage> get messages;

  /// Acknowledges the message so the server stops redelivering it. The
  /// archiver must call this ONLY after the record was durably written
  /// (K01 discipline, KB3) — never as a side effect of receiving it.
  Future<void> ack({required String senderId, required String messageId});
}

/// [GroupMessageSource] over the existing Signal-style per-recipient
/// fan-out (`SignalRClient` + `SessionManager` from calltype_core). This is
/// the same wire format the app and calltype_bot already speak — reused
/// here rather than forked, per KB2's "known limitation of step 1" note:
/// the archiver is just another ordinary recipient.
class SignalGroupMessageSource implements GroupMessageSource {
  SignalGroupMessageSource({
    required SignalRClient signalR,
    required SessionManager sessions,
    void Function(String line)? log,
  }) : _signalR = signalR,
       _sessions = sessions,
       _log = log ?? ((_) {});

  final SignalRClient _signalR;
  final SessionManager _sessions;
  final void Function(String) _log;

  /// Message ids whose decrypt failure was already logged — the server
  /// redelivers unacked messages every ~15s and would otherwise flood logs.
  final _reportedFailures = <String>{};

  /// Serializes ratchet state access: two interleaved decrypts for the same
  /// sender would corrupt the Double Ratchet chain keys (same rule as
  /// calltype_bot's `_crypto` queue).
  Future<void> _queue = Future.value();

  @override
  Stream<IncomingGroupMessage> get messages {
    final controller = StreamController<IncomingGroupMessage>.broadcast();
    controller.onListen = () {
      controller.addStream(
        _signalR.onMessage
            .where(_isGroupMessageElseDrop)
            .asyncMap(_decrypt)
            .where((event) => event != null)
            .cast<IncomingGroupMessage>(),
      );
    };
    return controller.stream;
  }

  /// The auditor only ever belongs to business GROUPS. A 1:1 message can be
  /// addressed to its device id by anyone; it is acknowledged WITHOUT being
  /// decrypted and dropped — left un-acked it would be redelivered every 15 s
  /// until its 30-day TTL, by every sender who cares to try.
  bool _isGroupMessageElseDrop(Map<String, dynamic> data) {
    if (data['groupId'] != null) return true;
    final senderId = data['senderId'] as String?;
    final messageId = data['messageId'] as String?;
    if (senderId != null && messageId != null) {
      unawaited(
        _signalR.acknowledgeMessage(senderId, messageId).catchError((_) {}),
      );
    }
    return false;
  }

  Future<IncomingGroupMessage?> _decrypt(Map<String, dynamic> data) {
    // Chained onto _queue (not awaited concurrently) so ratchet state is
    // never touched by two decrypts at once.
    final result = _queue.then((_) => _decryptOne(data));
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<IncomingGroupMessage?> _decryptOne(Map<String, dynamic> data) async {
    final senderId = data['senderId'] as String?;
    final messageId = data['messageId'] as String?;
    final groupId = data['groupId'] as String?;
    if (senderId == null || messageId == null || groupId == null) return null;

    try {
      final plaintext = await _sessions.decryptMessage(
        senderId,
        utf8.decode(base64Decode(data['encryptedBody'] as String)),
        deferPreKeyCleanup: true,
      );
      await _sessions.finalizePreKeyCleanup();
      final payload = jsonDecode(plaintext) as Map<String, dynamic>;
      if (payload['v'] != 1 ||
          payload['id'] != messageId ||
          payload['groupId'] != groupId ||
          payload['body'] is! String) {
        throw const FormatException('Message context mismatch');
      }

      final body = payload['body'] as String;
      final type = payloadType(payload);
      final sentAt =
          DateTime.tryParse(payload['createdAt'] as String? ?? '') ??
          DateTime.now().toUtc();
      IncomingGroupMessage record(
        String kind, {
        required int sizeBytes,
        required String hashedText,
        String? detailsJson,
      }) => IncomingGroupMessage(
        messageId: messageId,
        groupId: groupId,
        senderId: senderId,
        sentAt: sentAt,
        kind: kind,
        sizeBytes: sizeBytes,
        contentHashHex: _sha256(hashedText),
        detailsJson: detailsJson,
      );

      switch (type) {
        case MessageTypes.text:
          return record(
            'text',
            sizeBytes: utf8.encode(body).length,
            hashedText: body,
          );
        case MessageTypes.file:
          // Attachments travel inline as {name, data: base64} inside body
          // (Attachment.encode in the client) — there is no separate blob to
          // fetch, so "the decrypted attachment metadata envelope" IS body,
          // and sizeBytes is the real file size, not the JSON envelope's.
          final envelope = jsonDecode(body) as Map<String, dynamic>;
          return record(
            'attachment',
            sizeBytes: base64Decode(envelope['data'] as String).length,
            hashedText: body,
          );
        case MessageTypes.media:
          // M2 §4.6 / R4-A: metadata of the REFERENCE only. The blob is never
          // downloaded — the archiver must not hold content. A malformed
          // reference follows the content discipline below (not emitted,
          // not acked), like a malformed call-event.
          final ref = MediaRef.decode(body);
          return record('attachment', sizeBytes: ref.size, hashedText: body);
        case MessageTypes.callEvent:
          // Strict validation — same discipline as an undecryptable message:
          // a malformed call-event is not emitted (and so never acked), it is
          // just logged by id and left for the server to redeliver.
          _validateCallEventBody(body);
          // Verbatim — the server re-hashes this and must match the hash.
          return record(
            'call-metadata',
            sizeBytes: utf8.encode(body).length,
            hashedText: body,
            detailsJson: body,
          );
        case MessageTypes.groupUpdate:
          // G §4.2: membership/name changes are archived as metadata only.
          return record(
            'group-event',
            sizeBytes: utf8.encode(body).length,
            hashedText: body,
          );
        case MessageTypes.edit || MessageTypes.delete || MessageTypes.reaction:
          final details = _refDetails(type, payload);
          if (details == null) {
            // M §4.1: a malformed CONTROL message will not get better by
            // being redelivered — ack and drop. Left un-acked it would age
            // and flip the whole organization to auditor_unavailable.
            if (_reportedFailures.add(messageId)) {
              _log('Dropping malformed $type $messageId from $senderId');
            }
            await _ackWithoutRecord(senderId, messageId);
            return null;
          }
          return record(
            type,
            sizeBytes: details.sizeBytes,
            hashedText: details.json,
            detailsJson: details.json,
          );
      }
      if (isControlPayload(payload)) {
        // receipt (R-3), profile, device-list/sync/provision (never sent to
        // business groups) and any future control type: not conversation
        // content, nothing to archive — ack WITHOUT a record.
        await _ackWithoutRecord(senderId, messageId);
        return null;
      }
      // K2: content this archiver version does not understand still gets a
      // metadata record — acking it without one would leave a hole in the
      // KB3 chain, not acking it would block the organization after 24 h.
      final details = _otherDetails(type);
      return record(
        'other',
        sizeBytes: utf8.encode(body).length,
        hashedText: details,
        detailsJson: details,
      );
    } catch (error) {
      // Never acked: a message that can't be authenticated/parsed must not
      // be reported as archived. It stays queued server-side and is
      // redelivered — same discipline as the app and calltype_bot.
      if (_reportedFailures.add(messageId)) {
        _log('Cannot decrypt group message $messageId from $senderId: $error');
      }
      return null;
    }
  }

  @override
  Future<void> ack({required String senderId, required String messageId}) =>
      _signalR.acknowledgeMessage(senderId, messageId);

  /// For messages that are deliberately NOT archived (control messages):
  /// the record-then-ack rule of the Archiver does not apply because there
  /// is no record. Best effort — if the ack is lost, the redelivery decrypts
  /// fails (key spent) and is logged, like any duplicate.
  Future<void> _ackWithoutRecord(String senderId, String messageId) async {
    try {
      await _signalR.acknowledgeMessage(senderId, messageId);
    } catch (_) {}
  }
}

String _sha256(String text) =>
    crypto.sha256.convert(utf8.encode(text)).toString();

final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
  r'[0-9a-fA-F]{12}$',
);

/// `details` of edit/delete/reaction (M §4.2): exactly `{"ref","bodyHash"}`
/// in this key order — the server hashes the exact string it receives.
/// `bodyHash` = SHA-256 of the new text (edit) / the emoji (reaction),
/// null for delete. Null result = malformed message.
({String json, int sizeBytes})? _refDetails(
  String type,
  Map<String, dynamic> payload,
) {
  final rawRef = payload['ref'];
  if (rawRef is! String || !_uuid.hasMatch(rawRef)) return null;
  // The server compares against the canonical Guid "D" form (lowercase);
  // the hash is over the exact string, so normalise before serialising.
  final ref = rawRef.toLowerCase();
  final String? hashed;
  switch (type) {
    case MessageTypes.edit:
      hashed = payload['body'] as String;
    case MessageTypes.reaction:
      final emoji = payload['emoji'];
      if (emoji is! String || utf8.encode(emoji).length > 64) return null;
      hashed = emoji;
    default:
      hashed = null;
  }
  return (
    json: jsonEncode({
      'ref': ref,
      'bodyHash': hashed == null ? null : _sha256(hashed),
    }),
    sizeBytes: hashed == null ? 0 : utf8.encode(hashed).length,
  );
}

/// `details` of kind `other` (K2, server rule `invalid_other_details`):
/// exactly `{"type":"…"}` — the wire type without control characters, at
/// most 32 UTF-16 units (what the server's string length counts), and the
/// whole serialized details at most 64 characters (JSON escaping of `"` or
/// `\` can make it longer than type + 11). Never fails: an unknown type is
/// chosen by the SENDER, and a record the server rejects would stay
/// un-acked and push the organization into auditor_unavailable.
String _otherDetails(String type) {
  final clean = type.replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), '');
  final runes = <String>[];
  var units = 0;
  for (final rune in clean.runes) {
    final char = String.fromCharCode(rune);
    // Never split a surrogate pair.
    if (units + char.length > 32) break;
    runes.add(char);
    units += char.length;
  }
  while (true) {
    final type = runes.isEmpty ? 'unknown' : runes.join();
    final details = jsonEncode({'type': type});
    if (details.length <= 64) return details;
    runes.removeLast();
  }
}

// H1: the exact key set/enum rules the server (AuditArchiveEndpoints) also
// checks — kept identical on both sides so "well-formed" means the same
// thing whether validated here or there.
const _callDetailsKeys = {
  'callId',
  'role',
  'peerDeviceId',
  'startedAt',
  'endedAt',
  'media',
  'outcome',
};
const _callDetailsRoles = {'caller', 'callee'};
const _callDetailsMedia = {'audio', 'video'};
const _callDetailsOutcomes = {
  'completed',
  'missed',
  'rejected',
  'failed',
  'unavailable',
};
const _callDetailsMaxLength = 1024;

/// Throws [FormatException] on anything that isn't exactly the call-event
/// body shape (docs/superpowers/plans/2026-09-18-business-mode-contracts.md,
/// H1): no unknown/missing keys, closed enums, parseable timestamps,
/// endedAt >= startedAt when both are present.
void _validateCallEventBody(String body) {
  if (body.length > _callDetailsMaxLength) {
    throw const FormatException('call-event body exceeds max length');
  }
  final decoded = jsonDecode(body);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('call-event body must be a JSON object');
  }
  if (decoded.length != _callDetailsKeys.length ||
      !_callDetailsKeys.every(decoded.containsKey)) {
    throw const FormatException('call-event body has unknown/missing keys');
  }
  if (decoded['callId'] is! String) {
    throw const FormatException('call-event callId must be a string');
  }
  if (!_callDetailsRoles.contains(decoded['role'])) {
    throw const FormatException('call-event role invalid');
  }
  if (decoded['peerDeviceId'] is! String) {
    throw const FormatException('call-event peerDeviceId must be a string');
  }
  if (!_callDetailsMedia.contains(decoded['media'])) {
    throw const FormatException('call-event media invalid');
  }
  if (!_callDetailsOutcomes.contains(decoded['outcome'])) {
    throw const FormatException('call-event outcome invalid');
  }

  final startedAtRaw = decoded['startedAt'];
  if (startedAtRaw is! String) {
    throw const FormatException('call-event startedAt must be a string');
  }
  final startedAt = DateTime.tryParse(startedAtRaw);
  if (startedAt == null) {
    throw const FormatException('call-event startedAt does not parse');
  }

  final endedAtRaw = decoded['endedAt'];
  if (endedAtRaw == null) return;
  if (endedAtRaw is! String) {
    throw const FormatException('call-event endedAt must be a string or null');
  }
  final endedAt = DateTime.tryParse(endedAtRaw);
  if (endedAt == null) {
    throw const FormatException('call-event endedAt does not parse');
  }
  if (endedAt.isBefore(startedAt)) {
    throw const FormatException('call-event endedAt before startedAt');
  }
}
