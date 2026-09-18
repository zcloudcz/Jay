import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/crypto/group_cipher.dart';
import '../../core/crypto/session_manager.dart';
import '../../core/network/api_client.dart';
import '../../core/network/signalr_client.dart';
import '../../core/network/webrtc_manager.dart';
import '../../core/storage/database.dart';
import '../chat/message_inbox_service.dart';

/// H2 (Part B): app-wide listener that turns each business [CallReport] into
/// the `call-event` group message the archiver expects (H1). Deliberately a
/// SEPARATE service from [ChatController] rather than a method on it — a
/// call can end while no chat screen for that conversation is open, and this
/// must still run, exactly like [MessageInboxService] for incoming messages.
///
/// The body is sent through the SAME encrypt-then-outbox path a normal group
/// message uses (this file reimplements only that one path, not a second
/// crypto scheme) and the SAME [MessageProcessingQueue] the rest of the app
/// serializes ratchet updates through, so a call report can never interleave
/// with an ordinary send/receive on the same device.
class CallEventSender {
  CallEventSender({
    required AppDatabase database,
    required SignalRClient signalRClient,
    required SessionManager sessionManager,
    required ApiClient apiClient,
    required Stream<CallReport> callReports,
  }) : _db = database,
       _signalR = signalRClient,
       _sessions = sessionManager,
       _api = apiClient,
       _reports = callReports;

  final AppDatabase _db;
  final SignalRClient _signalR;
  final SessionManager _sessions;
  final ApiClient _api;
  final Stream<CallReport> _reports;
  StreamSubscription<CallReport>? _subscription;
  final _uuid = const Uuid();

  void start() {
    _subscription ??= _reports.listen((report) {
      unawaited(_enqueue(report));
    });
  }

  Future<void> _enqueue(CallReport report) =>
      MessageProcessingQueue.forDatabase(_db).run(() => _send(report));

  Future<void> _send(CallReport report) async {
    final groupId = report.businessGroupId;
    final messageId = _uuid.v4();
    // Exactly the six keys the archiver (jay_archiver/group_message_source)
    // and the server's re-validation expect — an extra or missing key means
    // the whole record is silently NOT archived.
    final body = jsonEncode({
      'callId': report.callId,
      'role': report.role,
      'peerDeviceId': report.peerDeviceId,
      'startedAt': report.startedAt.toUtc().toIso8601String(),
      'endedAt': report.endedAt.toUtc().toIso8601String(),
      'media': report.media,
      'outcome': report.outcome,
    });
    final now = DateTime.now();
    await _db.transaction(() async {
      await _db
          .into(_db.messages)
          .insert(
            MessagesCompanion.insert(
              id: messageId,
              conversationId: groupId,
              senderId: _signalR.deviceId,
              body: Value(body),
              type: const Value('call-event'),
              status: const Value('sending'),
              createdAt: now,
            ),
          );
      await (_db.update(_db.conversations)
            ..where((c) => c.id.equals(groupId)))
          .write(ConversationsCompanion(lastMessageAt: Value(now)));
    });
    await _deliver(messageId, groupId, body);
  }

  /// Encrypts and sends, retrying from the outbox on the next app start if
  /// the hub call fails (offline at hang-up) — same contract as
  /// `ChatController.retryMessage`'s outbox for an ordinary group message.
  Future<void> _deliver(String messageId, String groupId, String body) async {
    try {
      var stored = await (_db.select(
        _db.backupState,
      )..where((s) => s.key.equals('outbox:$messageId'))).getSingleOrNull();
      if (stored == null) {
        final recipients = (await _api.getGroupMembers(
          groupId,
        )).where((id) => id != _signalR.deviceId).toList();
        if (recipients.isEmpty) return;
        final payload = jsonEncode({
          'v': 1,
          'id': messageId,
          'body': body,
          'type': 'call-event',
          'groupId': groupId,
          'groupName': null,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
        });
        final envelopes = <String, String>{};
        await _db.transaction(() async {
          final encrypted = await GroupCipher(
            sessionManager: _sessions,
            ensureSession: _ensureSession,
          ).encryptForGroup(groupId, recipients, payload);
          envelopes.addAll(
            encrypted.map((id, bytes) => MapEntry(id, base64Encode(bytes))),
          );
          await _db
              .into(_db.backupState)
              .insert(
                BackupStateCompanion.insert(
                  key: 'outbox:$messageId',
                  value: jsonEncode({'groupId': groupId, 'envelopes': envelopes}),
                ),
              );
        });
        stored = await (_db.select(
          _db.backupState,
        )..where((s) => s.key.equals('outbox:$messageId'))).getSingle();
      }
      final outbox = jsonDecode(stored.value) as Map<String, dynamic>;
      final envelopes = (outbox['envelopes'] as Map<String, dynamic>)
          .cast<String, String>();
      await _signalR.sendGroupMessage(groupId, envelopes, messageId: messageId);
      await _db.transaction(() async {
        await (_db.update(_db.messages)..where((m) => m.id.equals(messageId)))
            .write(const MessagesCompanion(status: Value('sent')));
        await (_db.delete(
          _db.backupState,
        )..where((s) => s.key.equals('outbox:$messageId'))).go();
      });
    } catch (_) {
      // Left queued (message row + outbox entry, if it got that far) for a
      // retry — there is no user-facing retry button for a call report, so
      // it stays 'sending'/'failed' forever rather than silently vanishing.
      await (_db.update(_db.messages)..where((m) => m.id.equals(messageId)))
          .write(const MessagesCompanion(status: Value('failed')));
    }
  }

  Future<void> _ensureSession(String recipient) async {
    if (!await _sessions.hasSession(recipient)) {
      await _sessions.initiateSession(
        recipient,
        await _api.getKeyBundle(recipient),
      );
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
  }
}
