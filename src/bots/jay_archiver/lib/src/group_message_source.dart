import 'dart:async';
import 'dart:convert';

import 'package:calltype_core/messaging/group_topic.dart';
import 'package:calltype_core/messaging/pin.dart';
import 'package:calltype_core/messaging/poll.dart';
import 'package:calltype_core/messaging/reaction.dart';
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

  /// "text" | "attachment" | "call-metadata".
  final String kind;
  final int sizeBytes;

  /// Lowercase hex SHA-256 of the plaintext (text/attachment) or of
  /// [detailsJson] (call-metadata) — see ArchiveRecordRequest.ContentHash.
  final String contentHashHex;

  /// H1: only set for kind "call-metadata" — the exact call-event body
  /// string this was hashed from, sent verbatim as `details` so the
  /// archive keeps it readable (owner decision: a call is metadata, not
  /// content, so it is kept in clear rather than reduced to a hash).
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
      final type = payload['type'] as String? ?? 'text';
      // "text"/"file" are the app's own wire types (message_inbox_service.dart);
      // "call-event" (H1) is a client-generated report of a finished/missed
      // call; "reaction" is an emoji reaction (spec 2026-11-07), "pin" and
      // "poll-vote" are chat extras (spec 2026-11-08) and "group-topic" is a
      // group's topic (spec 2026-11-13-group-topics); those four are
      // archived as text metadata below. A poll itself is `text`. Anything
      // else is an unsupported message this archiver version cannot hash
      // meaningfully.
      if (type != 'text' &&
          type != 'file' &&
          type != 'call-event' &&
          type != 'reaction' &&
          type != pinType &&
          type != pollVoteType &&
          type != groupTopicType) {
        throw FormatException('Unsupported message type "$type"');
      }

      final sentAt =
          DateTime.tryParse(payload['createdAt'] as String? ?? '') ??
          DateTime.now().toUtc();

      if (type == 'call-event') {
        // Strict validation — same discipline as an undecryptable message:
        // a malformed call-event is not emitted (and so never acked), it is
        // just logged by id and left for the server to redeliver.
        _validateCallEventBody(body);
        return IncomingGroupMessage(
          messageId: messageId,
          groupId: groupId,
          senderId: senderId,
          sentAt: sentAt,
          kind: 'call-metadata',
          sizeBytes: utf8.encode(body).length,
          contentHashHex: crypto.sha256.convert(utf8.encode(body)).toString(),
          // Verbatim — the server re-hashes this and must match contentHashHex.
          detailsJson: body,
        );
      }

      if (type == 'reaction') {
        // WHY archived and not skipped: K01 "no ack without a durable write"
        // holds for every message a member sends. The app sends no reactions
        // into business groups (v1), so this is the defensive path for a
        // modified or future client. Kind `text`, because the audit API
        // knows no other kind and needs no change: the record carries only
        // size and hash of the body ({targetId, emoji}), never the content.
        // A malformed body is not emitted, like a malformed call-event.
        if (ReactionPayload.decode(body) == null) {
          throw const FormatException('reaction body is invalid');
        }
      }
      // Same reasoning for pins and votes (spec 2026-11-08-chat-extras): the
      // app sends none into business groups in v1; archived defensively,
      // metadata only.
      if (type == pinType && PinPayload.decode(body) == null) {
        throw const FormatException('pin body is invalid');
      }
      if (type == pollVoteType && PollVotePayload.decode(body) == null) {
        throw const FormatException('poll-vote body is invalid');
      }
      // Topics are refused for business groups by the server and the app
      // (spec 2026-11-13-group-topics row 11, K01); a modified client's one
      // is still archived, metadata only, like a pin.
      if (type == groupTopicType && GroupTopicPayload.decode(body) == null) {
        throw const FormatException('group-topic body is invalid');
      }

      final int sizeBytes;
      if (type == 'file') {
        // Attachments travel inline as {name, data: base64} inside body
        // (Attachment.encode in the client) — there is no separate blob to
        // fetch, so "the decrypted attachment metadata envelope" IS body,
        // and sizeBytes is the real file size, not the JSON envelope's.
        final envelope = jsonDecode(body) as Map<String, dynamic>;
        sizeBytes = (base64Decode(envelope['data'] as String)).length;
      } else {
        sizeBytes = utf8.encode(body).length;
      }

      return IncomingGroupMessage(
        messageId: messageId,
        groupId: groupId,
        senderId: senderId,
        sentAt: sentAt,
        kind: type == 'file' ? 'attachment' : 'text',
        sizeBytes: sizeBytes,
        contentHashHex: crypto.sha256.convert(utf8.encode(body)).toString(),
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
