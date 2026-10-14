import 'dart:convert';

import '../crypto/device_list.dart';
import '../crypto/session_manager.dart';
import '../network/api_client.dart';
import 'device_directory.dart';

/// Builds the per-device envelopes of one message and repairs them when the
/// hub answers `device_list_stale`.
///
/// The one rule that keeps the server from adding a reader: an envelope is
/// only ever created for a device from a VERIFIED list. The server may tell
/// us to drop a device (fewer readers is always safe) but if it demands one
/// we cannot verify, the send fails.
///
/// This class owns session setup (instead of taking a callback) so that a
/// listed companion's key bundle is compared with the signed list BEFORE it
/// is pinned.
class FanoutSender {
  FanoutSender({
    required DeviceDirectory directory,
    required SessionManager sessions,
    required ApiClient apiClient,
  }) : _directory = directory,
       _sessions = sessions,
       _api = apiClient;

  final DeviceDirectory _directory;
  final SessionManager _sessions;
  final ApiClient _api;

  /// One base64 envelope per device of [identityIds] and of our own other
  /// devices, from the STORED verified lists only: no network fetch here.
  ///
  /// A list we never fetched (or a new companion) is caught by the hub's
  /// completeness check -> `device_list_stale` -> [reconcile], which refreshes
  /// and verifies. That costs one extra round trip on the first message to a
  /// multi-device identity and nothing afterwards, whereas a GET per
  /// recipient per message would make a 50-member group cost 51 round trips
  /// (and every single-device contact a pointless GET).
  Future<Map<String, String>> encrypt(
    Iterable<String> identityIds,
    String payload,
  ) async {
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
    // Refresh only what differs between the hub's view and ours, otherwise a
    // 100-member group would spend the API's per-device request budget on one
    // reconcile. (a) Owners of devices we sent that the hub dropped: refreshing
    // makes the removal take effect on our side too, not only on an honest
    // server. (b) Required devices we cannot verify yet, by their own id (the
    // directory resolves it to the identity's list).
    final verifiedBefore = (await _directory.fanoutTargets(identityIds)).toSet();
    final toRefresh = <String>{
      for (final d in envelopes.keys.toSet().difference(required))
        await _directory.identityOf(d),
      ...required.difference(verifiedBefore),
    };
    await _refresh(toRefresh);
    final verified = (await _directory.fanoutTargets(identityIds)).toSet();
    // A kept device the refresh just showed as removed must not get the copy:
    // its envelope was made from an older list than the one we now trust.
    kept.removeWhere((device, _) => !verified.contains(device));
    if (missing.isEmpty) return kept;
    if (!verified.containsAll(missing)) {
      throw const DeviceListException('server_requires_unverified_device');
    }
    for (final target in missing) {
      kept[target] = await _encryptFor(target, payload);
    }
    return kept;
  }

  Future<void> _refresh(Iterable<String> deviceIds) async {
    for (final id in deviceIds) {
      try {
        await _directory.refresh(id, ensurePinned: _ensureSession);
      } catch (_) {
        // Any failure (a bad list, a 429/5xx or network error, a session that
        // cannot start) must not block a group send whose missing device
        // belongs to someone else. A failed refresh leaves the verified state
        // untouched; a required device that stays unverified is still refused
        // by the final check in reconcile.
      }
    }
  }

  /// Starts a session unless one exists. For a listed companion the served
  /// bundle must carry the keys its primary signed: compare BEFORE
  /// initiateSession, because that pins the keys and a pin cannot be taken
  /// back (a wrong pin would make every later honest list fail the
  /// directory's write-time pin check).
  Future<void> _ensureSession(String deviceId) async {
    if (await _sessions.hasSession(deviceId)) return;
    final bundle = await _api.getKeyBundle(deviceId);
    final expected = await _directory.expectedKeysOf(deviceId);
    if (expected != null &&
        '${bundle['identityKey']}|${bundle['signingKey']}' != expected) {
      throw const DeviceListException('listed_keys_mismatch');
    }
    await _sessions.initiateSession(deviceId, bundle);
  }

  Future<String> _encryptFor(String deviceId, String payload) async {
    await _ensureSession(deviceId);
    // Second line of defence, and the only one for sessions created by
    // receiving a pre-key message: the pinned keys must be the signed ones.
    await _directory.assertListedKeys(deviceId);
    return base64Encode(
      utf8.encode(await _sessions.encryptMessage(deviceId, payload)),
    );
  }
}
