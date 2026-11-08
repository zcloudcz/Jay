import 'dart:convert';

import 'package:dio/dio.dart' show DioException;

import 'package:calltype_protocol/crypto/device_list.dart';
import 'package:calltype_protocol/crypto/session_manager.dart';
import '../network/api_client.dart';
import '../network/signalr_client.dart' show SignalRClient;
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
    this.onMissingDevice,
  }) : _directory = directory,
       _sessions = sessions,
       _api = apiClient;

  /// Called for each listed companion skipped because the server no longer
  /// has its key bundle (404), so the app can surface or log it.
  final void Function(String deviceId)? onMissingDevice;

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
    final result = <String, String>{};
    for (final target in await _directory.fanoutTargets(identityIds)) {
      final envelope = await _encryptFor(target, payload);
      if (envelope != null) result[target] = envelope;
    }
    return result;
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
    var unreachable = false;
    for (final target in missing) {
      final envelope = await _encryptFor(target, payload);
      if (envelope == null) {
        unreachable = true;
      } else {
        kept[target] = envelope;
      }
    }
    // The hub insists on a device whose bundle is gone: we cannot reach it,
    // same outcome as a device we cannot verify.
    if (unreachable) {
      throw const DeviceListException('server_requires_unverified_device');
    }
    return kept;
  }

  /// Sends [envelopes] with [send] and, while the hub answers
  /// `device_list_stale`, repairs them with [reconcile] (at most
  /// [maxRounds] attempts) and hands every repaired set to [persist] before
  /// the next attempt, so a crash resends exactly those bytes. Any other
  /// error is rethrown unchanged.
  ///
  /// [identityIdsFor] may widen the identities before a repair (a group
  /// member added since the first attempt); it gets the current ones.
  ///
  /// Deliberately NOT inside a database transaction: reconcile refreshes
  /// device lists, DeviceDirectory serializes its refreshes, and a
  /// transaction held across that could wait for a refresh that waits for
  /// the database.
  Future<void> deliver({
    required Map<String, String> envelopes,
    required List<String> identityIds,
    required String payload,
    required Future<void> Function(Map<String, String> envelopes) send,
    required Future<void> Function(
      Map<String, String> envelopes,
      List<String> identityIds,
    )
    persist,
    Future<List<String>> Function(List<String> identityIds)? identityIdsFor,
    void Function(Set<String> required)? onStale,
    int maxRounds = 3,
  }) async {
    var current = envelopes;
    var ids = identityIds;
    for (var round = 1; ; round++) {
      try {
        await send(current);
        return;
      } catch (e) {
        final required = SignalRClient.staleRequired(e);
        if (required == null || round == maxRounds) rethrow;
        onStale?.call(required);
        if (identityIdsFor != null) ids = await identityIdsFor(ids);
        current = await reconcile(
          envelopes: current,
          required: required,
          identityIds: ids,
          payload: payload,
        );
        await persist(current, ids);
      }
    }
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

  /// Null when [deviceId] is a listed companion whose key bundle is gone from
  /// the server (404): skipped, because fewer readers is always safe, and if
  /// the device still exists the hub's completeness check asks for it again.
  /// A primary's 404 is a real error and propagates.
  Future<String?> _encryptFor(String deviceId, String payload) async {
    try {
      await _ensureSession(deviceId);
    } on DioException catch (e) {
      if (e.response?.statusCode != 404 ||
          await _directory.expectedKeysOf(deviceId) == null) {
        rethrow;
      }
      onMissingDevice?.call(deviceId);
      return null;
    }
    // Second line of defence, and the only one for sessions created by
    // receiving a pre-key message: the pinned keys must be the signed ones.
    await _directory.assertListedKeys(deviceId);
    return base64Encode(
      utf8.encode(await _sessions.encryptMessage(deviceId, payload)),
    );
  }
}
