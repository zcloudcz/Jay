import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/network/signalr_client.dart';
import '../../core/network/webrtc_manager.dart';
import 'call_ring.dart';

/// Glue between the system call UI (CallKit / Android full-screen call) and
/// [WebRTCManager] for calls that ring while the app is closed (call ringing
/// spec, section 2 "Dart flow"):
///
/// * accept -> connect the hub, `RequestPendingCalls()`, wait up to
///   [acceptTimeout] for the offer with that call id, answer it without the
///   in-app ringing screen (the session overlay then opens the call screen);
///   no offer in time -> end the system call, "missed call" notification;
/// * decline -> hub `DeclinePendingCall(callId)` (or a `declined` hangup when
///   the offer is already here), end the system call;
/// * `cancelled` signal -> end the system call, "missed call" notification;
/// * the call ends in the app -> end the system call; connected -> tell the
///   system UI; mute / hold from the system UI -> mute.
///
/// An offer for a call the system UI does not know keeps today's in-app
/// ringing: this class only acts on calls it has seen in [CallRingPlatform].
class CallRingCoordinator {
  CallRingCoordinator({
    required CallRingPlatform platform,
    required WebRTCManager calls,
    required SignalRClient signalR,
    required Future<void> Function(String? callerDeviceId) onMissedCall,
    this.acceptTimeout = const Duration(seconds: 10),
    this.staleAfter = const Duration(seconds: 60),
    DateTime Function()? now,
  }) : _platform = platform,
       _calls = calls,
       _signalR = signalR,
       _onMissedCall = onMissedCall,
       _now = now ?? DateTime.now;

  final CallRingPlatform _platform;
  final WebRTCManager _calls;
  final SignalRClient _signalR;
  final Future<void> Function(String? callerDeviceId) _onMissedCall;
  final DateTime Function() _now;

  /// How long an accepted call waits for its offer (spec: 10 s).
  final Duration acceptTimeout;

  /// Calls the platform still lists after this long are leftovers.
  final Duration staleAfter;

  final _rings = <String, _Ring>{};
  final _declined = <String>{};

  /// Calls already reported as missed (a timeout, then the tombstone's
  /// `cancelled` on the next connect, must not notify twice).
  final _missed = <String>{};
  final _subscriptions = <StreamSubscription<Object?>>[];
  bool _started = false;

  /// Lowercase ids of the calls currently tracked (tests, diagnostics).
  @visibleForTesting
  Iterable<String> get trackedCalls => _rings.keys;

  /// Starts listening and picks up calls the system UI already shows (an
  /// accept on the lock screen that launched the app). Never throws.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _subscriptions
      ..add(_platform.events.listen(_onEvent))
      ..add(_signalR.onCallSignal.listen(_onSignal));
    _calls.addListener(_onCallsChanged);
    try {
      final now = _now();
      for (final active in await _platform.activeCalls()) {
        final since = active.ringingSince;
        if (since != null && now.difference(since) > staleAfter) {
          // A leftover of an earlier run: never answer it.
          unawaited(_safe(() => _platform.end(active.callId)));
          continue;
        }
        if (active.accepted) {
          unawaited(_accept(active.callId));
        } else {
          _track(active.callId);
          unawaited(_fetchPending());
        }
      }
    } catch (_) {}
  }

  /// A ring push the app received while running (Android FCM in the
  /// foreground): the hub was down, so fetch the offer and let the in-app
  /// ringing UI take it (spec: foreground keeps today's ringing).
  void onForegroundPush(Map<String, String> data) {
    if (IncomingRing.fromPush(data) != null ||
        IncomingRing.fromPush(data, type: ringPushCancelled) != null) {
      unawaited(_fetchPending());
    }
  }

  Future<void> dispose() async {
    _calls.removeListener(_onCallsChanged);
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
    for (final ring in _rings.values) {
      ring.timer?.cancel();
    }
    _rings.clear();
  }

  // -- System UI events ---------------------------------------------------------

  void _onEvent(RingEvent event) {
    final callId = event.callId.toLowerCase();
    switch (event) {
      case RingIncoming():
        _track(callId);
        // Fetch the offer while it rings: accepting is faster and a caller
        // who gives up is seen (`cancelled`) while the phone still rings.
        unawaited(_fetchPending());
      case RingAccepted():
        unawaited(_accept(callId));
      case RingDeclined():
        unawaited(_decline(callId));
      case RingEnded():
        unawaited(_systemEnded(callId));
      case RingTimedOut():
        unawaited(_timedOut(callId));
      case RingMuted(:final muted):
        if (_calls.callId?.toLowerCase() == callId) _calls.setMuted(muted);
    }
  }

  _Ring _track(String callId) {
    final id = callId.toLowerCase();
    _calls.markSystemCall(id);
    return _rings.putIfAbsent(id, () => _Ring(id));
  }

  bool _offerReady(String callId) =>
      _calls.isIncoming && _calls.callId?.toLowerCase() == callId;

  Future<void> _accept(String callId) async {
    final ring = _track(callId);
    if (ring.accepted) return;
    ring.accepted = true;
    if (_offerReady(callId)) {
      _answer(ring);
      return;
    }
    ring.timer = Timer(acceptTimeout, () => unawaited(_acceptTimedOut(ring)));
    await _fetchPending();
    // The offer may have arrived while connecting.
    _onCallsChanged();
  }

  void _answer(_Ring ring) {
    if (ring.answering) return;
    ring.answering = true;
    ring.timer?.cancel();
    ring.seen = true;
    unawaited(_safe(_calls.acceptCall));
  }

  Future<void> _acceptTimedOut(_Ring ring) async {
    if (_rings[ring.callId] != ring || ring.answering) return;
    _rings.remove(ring.callId);
    _remember(_missed, ring.callId);
    await _safe(() => _platform.end(ring.callId));
    await _safe(() => _onMissedCall(null));
  }

  Future<void> _decline(String callId) async {
    _rings.remove(callId)?.timer?.cancel();
    _remember(_declined, callId);
    if (_offerReady(callId)) {
      // The offer is already here: the hub has no pending call any more,
      // the caller learns from our hangup (payload "declined").
      await _safe(_calls.endCall);
    } else {
      await _fetch(() => _signalR.declinePendingCall(callId));
    }
    await _safe(() => _platform.end(callId));
  }

  Future<void> _systemEnded(String callId) async {
    _rings.remove(callId)?.timer?.cancel();
    if (_calls.callId?.toLowerCase() == callId &&
        _calls.state != CallState.ended &&
        _calls.state != CallState.idle) {
      await _safe(_calls.endCall);
    }
  }

  Future<void> _timedOut(String callId) async {
    final ring = _rings.remove(callId);
    ring?.timer?.cancel();
    if (_offerReady(callId)) {
      _remember(_declined, callId);
      await _safe(_calls.endCall);
    }
    _remember(_missed, callId);
    if (!_platform.showsMissedOnTimeout) {
      await _safe(() => _onMissedCall(null));
    }
  }

  // -- Hub signals ----------------------------------------------------------------

  void _onSignal(Map<String, dynamic> data) {
    if (data['signalType'] != 'cancelled') return;
    final callId = _callIdOf(data['payload']);
    if (callId == null) return;
    final sender = data['senderId'];
    final ring = _rings.remove(callId);
    ring?.timer?.cancel();
    if (ring != null) unawaited(_safe(() => _platform.end(callId)));
    if (!_remember(_missed, callId)) return;
    // R6: the caller gave up while this device was offline or ringing.
    unawaited(_safe(() => _onMissedCall(sender is String ? sender : null)));
  }

  static String? _callIdOf(Object? payload) {
    if (payload is! String) return null;
    try {
      final decoded = jsonDecode(payload);
      final id = decoded is Map ? decoded['callId'] : null;
      return id is String && id.isNotEmpty ? id.toLowerCase() : null;
    } on FormatException {
      return null;
    }
  }

  // -- Call state -------------------------------------------------------------------

  void _onCallsChanged() {
    final current = _calls.callId?.toLowerCase();
    final active =
        _calls.state != CallState.ended && _calls.state != CallState.idle;
    if (current != null && _calls.isIncoming && _declined.contains(current)) {
      // Declined on the lock screen, but the offer was already on its way.
      unawaited(_safe(_calls.endCall));
      return;
    }
    for (final ring in List.of(_rings.values)) {
      if (current == ring.callId && active) {
        ring.seen = true;
        if (ring.accepted && _calls.isIncoming) _answer(ring);
        if (_calls.state == CallState.connected && !ring.connected) {
          ring.connected = true;
          unawaited(_safe(() => _platform.setConnected(ring.callId)));
        }
      } else if (ring.seen) {
        // The call this ring stood for is over in the app (hangup on either
        // side, failure, timeout): the system UI must not keep showing it.
        _rings.remove(ring.callId);
        ring.timer?.cancel();
        unawaited(_safe(() => _platform.end(ring.callId)));
      }
    }
  }

  // -- Helpers ------------------------------------------------------------------------

  /// Adds [callId] to a small bounded [set]; false when it was there.
  static bool _remember(Set<String> set, String callId) {
    if (!set.add(callId)) return false;
    if (set.length > 32) set.remove(set.first);
    return true;
  }

  Future<void> _fetchPending() => _fetch(_signalR.requestPendingCalls);

  /// Connects the hub if needed, then runs [action]. Best effort: a failure
  /// surfaces as the accept timeout, never as an exception.
  Future<void> _fetch(Future<void> Function() action) async {
    try {
      if (!_signalR.connected) await _signalR.connect();
      await action();
    } catch (_) {}
  }

  static Future<void> _safe(FutureOr<void> Function() action) async {
    try {
      await action();
    } catch (_) {}
  }
}

class _Ring {
  _Ring(this.callId);
  final String callId;
  bool accepted = false;
  bool answering = false;

  /// The manager has (or had) this call: its end ends the system call.
  bool seen = false;
  bool connected = false;
  Timer? timer;
}
