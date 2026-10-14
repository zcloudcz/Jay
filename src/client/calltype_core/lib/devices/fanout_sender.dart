import 'dart:convert';

import '../crypto/device_list.dart';
import '../crypto/session_manager.dart';
import 'device_directory.dart';

/// Builds the per-device envelopes of one message and repairs them when the
/// hub answers `device_list_stale`.
///
/// The one rule that keeps the server from adding a reader: an envelope is
/// only ever created for a device from a VERIFIED list. The server may tell
/// us to drop a device (fewer readers is always safe) but if it demands one
/// we cannot verify, the send fails.
class FanoutSender {
  FanoutSender({
    required DeviceDirectory directory,
    required SessionManager sessions,
    required Future<void> Function(String deviceId) ensureSession,
  }) : _directory = directory,
       _sessions = sessions,
       _ensureSession = ensureSession;

  final DeviceDirectory _directory;
  final SessionManager _sessions;
  final Future<void> Function(String) _ensureSession;

  /// One base64 envelope per device of [identityIds] and of our own other
  /// devices. Refreshes the lists first so a contact's new device is picked
  /// up without waiting for a stale error.
  Future<Map<String, String>> encrypt(
    Iterable<String> identityIds,
    String payload,
  ) async {
    await _refresh(identityIds);
    return {
      for (final target in await _directory.fanoutTargets(identityIds))
        target: await _encryptFor(target, payload),
    };
  }

  /// After `device_list_stale`: [required] is the device set the hub wants.
  /// Existing envelopes are kept byte for byte (re-encrypting would advance
  /// the ratchet for a message the peer may already hold).
  Future<Map<String, String>> reconcile({
    required Map<String, String> envelopes,
    required Set<String> required,
    required Iterable<String> identityIds,
    required String payload,
  }) async {
    final kept = {
      for (final e in envelopes.entries)
        if (required.contains(e.key)) e.key: e.value,
    };
    final missing = required.difference(kept.keys.toSet());
    if (missing.isEmpty) return kept;
    await _refresh(identityIds);
    final verified = (await _directory.fanoutTargets(identityIds)).toSet();
    if (!verified.containsAll(missing)) {
      throw const DeviceListException('server_requires_unverified_device');
    }
    for (final target in missing) {
      kept[target] = await _encryptFor(target, payload);
    }
    return kept;
  }

  Future<void> _refresh(Iterable<String> identityIds) async {
    for (final id in {...identityIds, _directory.selfIdentityId}) {
      await _directory.refresh(id, ensurePinned: _ensureSession);
    }
  }

  Future<String> _encryptFor(String deviceId, String payload) async {
    await _ensureSession(deviceId);
    // After the session exists the device's keys are pinned: they must be
    // the ones its primary signed.
    await _directory.assertListedKeys(deviceId);
    return base64Encode(
      utf8.encode(await _sessions.encryptMessage(deviceId, payload)),
    );
  }
}
