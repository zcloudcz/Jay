import 'dart:async';
import 'dart:convert';

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
  });

  final String messageId;
  final String groupId;
  final String senderId;
  final DateTime sentAt;

  /// "text" | "attachment" — call metadata is out of scope for E03-lite
  /// (no call-signaling archival exists yet in the Delivery hub).
  final String kind;
  final int sizeBytes;

  /// Lowercase hex SHA-256 of the plaintext (text) or of the decrypted
  /// attachment envelope (attachment) — see ArchiveRecordRequest.ContentHash.
  final String contentHashHex;
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
            .where((data) => data['groupId'] != null)
            .asyncMap(_decrypt)
            .where((event) => event != null)
            .cast<IncomingGroupMessage>(),
      );
    };
    return controller.stream;
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
      // Only "text" and "file" (the app's own wire types, see
      // message_inbox_service.dart) exist today; anything else is an
      // unsupported message this archiver version cannot hash meaningfully.
      if (type != 'text' && type != 'file') {
        throw FormatException('Unsupported message type "$type"');
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
        sentAt:
            DateTime.tryParse(payload['createdAt'] as String? ?? '') ??
            DateTime.now().toUtc(),
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
