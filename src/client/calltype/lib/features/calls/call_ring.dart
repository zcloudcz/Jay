import 'package:uuid/uuid.dart';

/// Shared vocabulary of call ringing on a closed app (spec
/// docs/superpowers/specs/2026-11-06-call-ringing.md, section 2): the system
/// call UI (CallKit on iOS, the full-screen call notification on Android)
/// sits behind [CallRingPlatform] so the coordinator is testable without
/// plugins.

/// Push data `type` of a ring push (R3) and of its Android cancel (R6).
const ringPushIncoming = 'incoming_call';
const ringPushCancelled = 'call_cancelled';

final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

/// The id the system call UI uses for [callId]: the call id itself when it
/// is a UUID (always true for calls this app starts), otherwise a
/// deterministic UUIDv5 of it in the URL namespace. AppDelegate.swift
/// computes the same value for VoIP pushes, so both sides agree on the id.
String ringIdFor(String callId) => _uuid.hasMatch(callId)
    ? callId.toLowerCase()
    : const Uuid().v5(Namespace.url.value, callId);

/// A ring the platform should show: only metadata-free ids (R4).
class IncomingRing {
  const IncomingRing({required this.callId, this.conversationId});

  final String callId;
  final String? conversationId;

  /// Parses push data `{type, callId, conversationId, v}`; null when it is
  /// not a usable ring push of [type].
  static IncomingRing? fromPush(
    Map<String, Object?> data, {
    String type = ringPushIncoming,
  }) {
    final callId = data['callId'];
    if (data['type'] != type || callId is! String) return null;
    if (callId.isEmpty || callId.length > 64) return null;
    final conversationId = data['conversationId'];
    return IncomingRing(
      callId: callId,
      conversationId: conversationId is String ? conversationId : null,
    );
  }
}

/// A call the system UI still knows about (app start after an accept on the
/// lock screen / full-screen notification).
class ActiveRing {
  const ActiveRing({
    required this.callId,
    required this.accepted,
    this.ringingSince,
  });

  final String callId;
  final bool accepted;

  /// When the ring was shown, if the platform kept it; stale entries are
  /// ignored (Android keeps the last call around).
  final DateTime? ringingSince;
}

/// What the user did in the system call UI. [callId] is the app's call id.
sealed class RingEvent {
  const RingEvent(this.callId);
  final String callId;
}

/// The system UI started ringing (iOS: reported from the VoIP push).
class RingIncoming extends RingEvent {
  const RingIncoming(super.callId);
}

class RingAccepted extends RingEvent {
  const RingAccepted(super.callId);
}

class RingDeclined extends RingEvent {
  const RingDeclined(super.callId);
}

/// An accepted call was ended from the system UI.
class RingEnded extends RingEvent {
  const RingEnded(super.callId);
}

/// Nobody answered before the ring duration ran out.
class RingTimedOut extends RingEvent {
  const RingTimedOut(super.callId);
}

/// Mute (or hold, which the app maps to mute) from the system UI.
class RingMuted extends RingEvent {
  const RingMuted(super.callId, this.muted);
  final bool muted;
}

/// The system call UI. Implemented with flutter_callkit_incoming in
/// `callkit_ring_platform.dart`, faked in tests.
abstract class CallRingPlatform {
  Stream<RingEvent> get events;

  /// Shows the incoming call (Android full-screen notification). On iOS the
  /// call is reported natively from the VoIP push, never from Dart.
  Future<void> showIncoming(IncomingRing ring);

  /// Ends / dismisses the system call for [callId] (no-op when unknown).
  Future<void> end(String callId);

  /// The media is flowing (starts the call timer in the system UI).
  Future<void> setConnected(String callId);

  /// Calls the system UI still shows, for recovery at app start.
  Future<List<ActiveRing>> activeCalls();

  /// Whether the platform shows its own missed-call notification when a
  /// ring times out (Android: yes, with the app's texts; iOS: no, the
  /// native report cannot be localized, so the app shows one).
  bool get showsMissedOnTimeout;
}

/// Android 14+ permission to show the incoming call full screen on the lock
/// screen (without it the call rings as a heads-up notification). Settings >
/// Notifications offers the system setting when it is missing.
abstract class FullScreenIntentAccess {
  Future<bool> canUseFullScreenIntent();
  Future<void> requestFullScreenIntent();
}
