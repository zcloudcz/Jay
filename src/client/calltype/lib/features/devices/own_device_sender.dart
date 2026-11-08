import 'dart:async';
import 'dart:convert';

import 'package:calltype_core/devices/device_directory.dart';
import 'package:calltype_core/devices/fanout_sender.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/crypto/session_manager.dart';
import '../../core/network/api_client.dart';
import '../../core/network/signalr_client.dart';
import '../../core/storage/database.dart';
import '../chat/message_inbox_service.dart' show MessageProcessingQueue;

/// BackupState key prefix of a pending own-device message: the exact
/// envelopes and payload, so a retry after a failed hub call resends the
/// same bytes (like a chat `outbox:` entry, but without a messages row).
const ownSyncOutboxPrefix = 'ownsync:';

/// Sends encrypted control messages to this identity's OTHER devices
/// (spec 2026-11-08-contact-sync): contact sync and history transfer.
///
/// Transport is the ordinary direct fan-out addressed to our own primary;
/// the hub then requires exactly our other devices. Envelopes come from
/// [FanoutSender] (verified lists only) and a stale answer is repaired by
/// [FanoutSender.deliver], the same path a chat message takes. Everything
/// runs in [MessageProcessingQueue], so a ratchet step can never interleave
/// with a chat send or the inbox.
class OwnDeviceSender {
  OwnDeviceSender({
    required AppDatabase database,
    required SignalRClient signalRClient,
    required SessionManager sessionManager,
    required ApiClient apiClient,
    required DeviceDirectory Function() directory,
  }) : _db = database,
       _signalR = signalRClient,
       _sessions = sessionManager,
       _api = apiClient,
       _directory = directory;

  final AppDatabase _db;
  final SignalRClient _signalR;
  final SessionManager _sessions;
  final ApiClient _api;

  /// A getter: a fresh install opens its directory only after onboarding.
  final DeviceDirectory Function() _directory;
  static const _uuid = Uuid();

  /// Our other devices in the verified own list (empty when unlinked).
  Future<List<String>> otherDevices() async {
    final directory = _directory();
    return [
      for (final d in await directory.devicesOf(directory.selfIdentityId))
        if (d != directory.selfDeviceId) d,
    ];
  }

  /// Sends one message of [type] with [body] to every other own device.
  /// Returns false when there is no other device (nothing is sent: the hub
  /// would refuse an empty fan-out) or the send failed; a failed send stays
  /// queued and [resendPending] retries it.
  Future<bool> send(String type, String body) async {
    final messageId = _uuid.v4();
    final queued = await MessageProcessingQueue.forDatabase(_db).run(() async {
      final directory = _directory();
      final fanout = _fanoutSender(directory);
      final payload = jsonEncode({
        'v': 1,
        'id': messageId,
        'type': type,
        'body': body,
        'groupId': null,
        'to': directory.selfIdentityId,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
      });
      return _db.transaction(() async {
        final envelopes = await fanout.encrypt(const [], payload);
        if (envelopes.isEmpty) return false;
        await _db
            .into(_db.backupState)
            .insert(
              BackupStateCompanion.insert(
                key: '$ownSyncOutboxPrefix$messageId',
                value: jsonEncode({'envelopes': envelopes, 'payload': payload}),
              ),
            );
        return true;
      });
    });
    if (!queued) return false;
    return _deliver(messageId);
  }

  /// Retries every queued own-device message (after a reconnect).
  Future<void> resendPending() async {
    final pending = await (_db.select(
      _db.backupState,
    )..where((s) => s.key.like('$ownSyncOutboxPrefix%'))).get();
    for (final row in pending) {
      await _deliver(row.key.substring(ownSyncOutboxPrefix.length));
    }
  }

  Future<bool> _deliver(String messageId) =>
      MessageProcessingQueue.forDatabase(_db).run(() async {
        final key = '$ownSyncOutboxPrefix$messageId';
        final stored = await (_db.select(
          _db.backupState,
        )..where((s) => s.key.equals(key))).getSingleOrNull();
        if (stored == null) return true;
        final outbox = jsonDecode(stored.value) as Map<String, dynamic>;
        final payload = outbox['payload'] as String;
        final directory = _directory();
        try {
          await _fanoutSender(directory).deliver(
            envelopes: (outbox['envelopes'] as Map<String, dynamic>)
                .cast<String, String>(),
            identityIds: const [],
            payload: payload,
            send: (current) {
              // Every own device was removed meanwhile: nothing to deliver.
              if (current.isEmpty) return Future.value();
              return _signalR.sendDirectFanout(
                directory.selfIdentityId,
                current,
                messageId: messageId,
              );
            },
            persist: (current, _) =>
                (_db.update(
                  _db.backupState,
                )..where((s) => s.key.equals(key))).write(
                  BackupStateCompanion(
                    value: Value(
                      jsonEncode({'envelopes': current, 'payload': payload}),
                    ),
                  ),
                ),
          );
        } catch (_) {
          // Stays queued for resendPending; the caller reports false.
          return false;
        }
        await (_db.delete(
          _db.backupState,
        )..where((s) => s.key.equals(key))).go();
        return true;
      });

  FanoutSender _fanoutSender(DeviceDirectory directory) =>
      FanoutSender(directory: directory, sessions: _sessions, apiClient: _api);
}
