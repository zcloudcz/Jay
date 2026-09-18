import 'dart:async';

import 'package:dio/dio.dart';

import 'group_message_source.dart';

/// Thrown when the archive API rejects the archiver's own credentials
/// (401/403) — the process should stop rather than spin forever archiving
/// nothing, per the package spec ("exit non-zero on auth errors").
class ArchiverAuthException implements Exception {
  ArchiverAuthException(this.statusCode);
  final int? statusCode;
  @override
  String toString() => 'Archive API rejected credentials (HTTP $statusCode)';
}

/// Consumes a [GroupMessageSource] and writes one metadata record per
/// message to `POST /orgs/{orgId}/audit/records`, ACKing only after a
/// successful (2xx) write — the K01 discipline named throughout the plan:
/// "no ACK without durable archive write".
class Archiver {
  Archiver({
    required GroupMessageSource source,
    required Dio api,
    required String organizationId,
    void Function(String line)? log,
    int maxAttempts = 5,
    Duration Function(int attempt)? backoff,
  }) : _source = source,
       _api = api,
       _orgId = organizationId,
       _log = log ?? ((_) {}),
       _maxAttempts = maxAttempts,
       _backoff = backoff ?? _defaultBackoff;

  final GroupMessageSource _source;
  final Dio _api;
  final String _orgId;
  final void Function(String) _log;
  final int _maxAttempts;
  final Duration Function(int) _backoff;

  /// Messages already archived+acked this run — a redelivered message (the
  /// server's 15s pending-message sweep) must not be POSTed twice even
  /// though the API is itself idempotent; this just avoids the extra call.
  final _acked = <String>{};

  StreamSubscription<IncomingGroupMessage>? _subscription;

  /// One at a time: two POSTs for messages from the same fast-moving group
  /// racing each other would gain nothing and complicate error handling.
  Future<void> _queue = Future.value();

  static Duration _defaultBackoff(int attempt) =>
      Duration(seconds: 1 << attempt.clamp(0, 5)); // 2s, 4s, 8s, ... capped

  /// Starts consuming the source. Completes only on an unrecoverable error
  /// (auth failure) or when [stop] is called.
  Future<void> run() {
    final done = Completer<void>();
    _subscription = _source.messages.listen(
      (message) {
        _queue = _queue.then((_) => _process(message)).catchError((
          Object error,
        ) {
          if (error is ArchiverAuthException && !done.isCompleted) {
            done.completeError(error);
          }
        });
      },
      onError: (Object error) {
        if (!done.isCompleted) done.completeError(error);
      },
    );
    return done.future;
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    await _queue;
  }

  Future<void> _process(IncomingGroupMessage message) async {
    if (_acked.contains(message.messageId)) {
      await _source.ack(
        senderId: message.senderId,
        messageId: message.messageId,
      );
      return;
    }

    for (var attempt = 1; ; attempt++) {
      try {
        await _api.post(
          '/orgs/$_orgId/audit/records',
          data: {
            'groupId': message.groupId,
            'messageId': message.messageId,
            'senderDeviceId': message.senderId,
            'sentAt': message.sentAt.toUtc().toIso8601String(),
            'kind': message.kind,
            'sizeBytes': message.sizeBytes,
            'contentHash': message.contentHashHex,
            // H1: only call-metadata carries details (the clear-text body
            // this was hashed from); every other kind sends null, and the
            // server rejects a non-null details for any other kind.
            if (message.detailsJson != null) 'details': message.detailsJson,
          },
        );
        break;
      } on DioException catch (e) {
        final status = e.response?.statusCode;
        if (status == 401 || status == 403) throw ArchiverAuthException(status);
        if (attempt >= _maxAttempts) {
          // Give up for now: leave it un-acked so the server's redelivery
          // sweep hands it back to us later (K01 — never ack without a
          // durable write).
          _log(
            'Giving up archiving ${message.messageId} after $attempt attempts: $e',
          );
          return;
        }
        await Future<void>.delayed(_backoff(attempt));
      }
    }

    await _source.ack(
      senderId: message.senderId,
      messageId: message.messageId,
    );
    _acked.add(message.messageId);
  }
}
