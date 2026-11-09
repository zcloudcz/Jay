// CallRingCoordinator: the Dart flow of call ringing on a closed app (spec
// docs/superpowers/specs/2026-11-06-call-ringing.md, section 2) against a
// fake system call UI, a fake hub and a real WebRTCManager.

import 'package:calltype/core/network/webrtc_manager.dart';
import 'package:calltype/features/calls/call_ring.dart';
import 'package:calltype/features/calls/call_ring_coordinator.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../helpers/fake_calls.dart';

const callId = '11223344-5566-4788-9900-aabbccddeeff';

void main() {
  late CallTestSignal signal;
  late WebRTCManager calls;
  late FakeRingPlatform platform;
  late List<String?> missed;
  late List<CallTestPeer> peers;
  late CallRingCoordinator coordinator;

  CallRingCoordinator build({bool showsMissed = false}) {
    platform = FakeRingPlatform(showsMissedOnTimeout: showsMissed);
    return coordinator = CallRingCoordinator(
      platform: platform,
      calls: calls,
      signalR: signal,
      onMissedCall: (caller) async => missed.add(caller),
    );
  }

  setUp(() {
    signal = CallTestSignal();
    peers = [];
    calls = testCallManager(signal, peers: peers);
    missed = [];
  });

  tearDown(() async {
    await coordinator.dispose();
    calls.dispose();
    await signal.signals.close();
  });

  test('accept connects, fetches the offer and answers it without the '
      'in-app ringing UI', () async {
    build();
    await coordinator.start();
    var sawInAppRinging = false;
    calls.addListener(() {
      if (calls.isIncoming && !calls.ringsInSystemUi) sawInAppRinging = true;
    });
    signal.onRequestPendingCalls = () =>
        signal.deliver('caller', 'offer', callId);

    platform.controller.add(const RingAccepted(callId));
    await pumpEventQueue();

    expect(signal.connects, 1);
    expect(signal.hub, ['RequestPendingCalls']);
    expect(signal.sent, contains('answer v=0'));
    expect(calls.state, CallState.connecting);
    expect(sawInAppRinging, isFalse);
    expect(platform.ended, isEmpty);

    // Media flows: the system UI starts its call timer.
    peers.single.onIceConnectionState?.call(
      RTCIceConnectionState.RTCIceConnectionStateConnected,
    );
    expect(platform.connected, [callId]);
  });

  test('an offer that arrived while CallKit rings stays out of the in-app '
      'UI and is answered on accept', () async {
    build();
    await coordinator.start();
    platform.controller.add(const RingIncoming(callId));
    await pumpEventQueue();
    expect(signal.hub, ['RequestPendingCalls']);

    signal.deliver('caller', 'offer', callId);
    await pumpEventQueue();
    expect(calls.isIncoming, isTrue);
    expect(calls.ringsInSystemUi, isTrue);

    platform.controller.add(const RingAccepted(callId));
    await pumpEventQueue();
    expect(signal.sent, contains('answer v=0'));
  });

  test('accept without an offer within 10 s ends the system call and '
      'reports a missed call', () {
    fakeAsync((async) {
      build();
      coordinator.start();
      async.flushMicrotasks();
      platform.controller.add(const RingAccepted(callId));
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 9));
      expect(platform.ended, isEmpty);
      async.elapse(const Duration(seconds: 2));
      expect(platform.ended, [callId]);
      expect(missed, [null]);
      expect(signal.sent, isEmpty);
    });
  });

  test('decline calls DeclinePendingCall and ends the system call', () async {
    build();
    await coordinator.start();
    platform.controller.add(const RingDeclined(callId));
    await pumpEventQueue();

    expect(signal.hub, ['DeclinePendingCall $callId']);
    expect(platform.ended, [callId]);

    // The offer was already on its way: it is declined, never rung in-app.
    signal.deliver('caller', 'offer', callId);
    await pumpEventQueue();
    expect(signal.sent, ['hangup declined']);
    expect(calls.state, CallState.ended);
  });

  test('decline after the offer arrived sends a declined hangup', () async {
    build();
    await coordinator.start();
    platform.controller.add(const RingIncoming(callId));
    signal.deliver('caller', 'offer', callId);
    await pumpEventQueue();

    platform.controller.add(const RingDeclined(callId));
    await pumpEventQueue();
    expect(signal.sent, ['hangup declined']);
    expect(signal.hub, isNot(contains('DeclinePendingCall $callId')));
  });

  test('cancelled for a ringing call ends it and reports a missed call '
      'once', () async {
    build();
    await coordinator.start();
    platform.controller.add(const RingIncoming(callId));
    await pumpEventQueue();

    signal.deliver('caller-device', 'cancelled', callId, '');
    signal.deliver('caller-device', 'cancelled', callId, '');
    await pumpEventQueue();

    expect(platform.ended, [callId]);
    expect(missed, ['caller-device']);
    expect(coordinator.trackedCalls, isEmpty);
  });

  test('a hangup in the app ends the system call', () async {
    build();
    await coordinator.start();
    signal.onRequestPendingCalls = () =>
        signal.deliver('caller', 'offer', callId);
    platform.controller.add(const RingAccepted(callId));
    await pumpEventQueue();
    expect(calls.state, CallState.connecting);

    await calls.endCall();
    await pumpEventQueue();
    expect(platform.ended, [callId]);
  });

  test('the caller hanging up mid-call ends the system call', () async {
    build();
    await coordinator.start();
    signal.onRequestPendingCalls = () =>
        signal.deliver('caller', 'offer', callId);
    platform.controller.add(const RingAccepted(callId));
    await pumpEventQueue();

    signal.deliver('caller', 'hangup', callId, '');
    await pumpEventQueue();
    expect(calls.state, CallState.ended);
    expect(platform.ended, [callId]);
  });

  test('ending from the system UI hangs up the call', () async {
    build();
    await coordinator.start();
    signal.onRequestPendingCalls = () =>
        signal.deliver('caller', 'offer', callId);
    platform.controller.add(const RingAccepted(callId));
    await pumpEventQueue();

    platform.controller.add(const RingEnded(callId));
    await pumpEventQueue();
    expect(calls.state, CallState.ended);
    expect(signal.sent.last, 'hangup');
  });

  test('mute and hold from the system UI mute the microphone', () async {
    build();
    await coordinator.start();
    signal.onRequestPendingCalls = () =>
        signal.deliver('caller', 'offer', callId);
    platform.controller.add(const RingAccepted(callId));
    await pumpEventQueue();

    platform.controller.add(const RingMuted(callId, true));
    expect(calls.isMuted, isTrue);
    platform.controller.add(const RingMuted(callId, false));
    expect(calls.isMuted, isFalse);
  });

  test('an accept on the lock screen that launched the app is picked up; '
      'stale leftovers are only dismissed', () async {
    build();
    const stale = '99887766-5544-4788-9900-aabbccddeeff';
    platform.active = [
      ActiveRing(callId: callId, accepted: true, ringingSince: DateTime.now()),
      ActiveRing(
        callId: stale,
        accepted: true,
        ringingSince: DateTime.now().subtract(const Duration(minutes: 5)),
      ),
    ];
    signal.onRequestPendingCalls = () =>
        signal.deliver('caller', 'offer', callId);
    await coordinator.start();
    await pumpEventQueue();

    expect(signal.sent, contains('answer v=0'));
    expect(platform.ended, [stale]);
  });

  test('ring timeout: iOS shows a missed call, Android leaves it to the '
      'platform', () async {
    build();
    await coordinator.start();
    platform.controller.add(const RingIncoming(callId));
    platform.controller.add(const RingTimedOut(callId));
    await pumpEventQueue();
    expect(missed, [null]);
    // The tombstone's `cancelled` on the next connect does not repeat it.
    signal.deliver('caller', 'cancelled', callId, '');
    await pumpEventQueue();
    expect(missed, [null]);

    await coordinator.dispose();
    build(showsMissed: true);
    await coordinator.start();
    missed.clear();
    platform.controller.add(
      const RingTimedOut('aaaaaaaa-5566-4788-9900-aabbccddeeff'),
    );
    await pumpEventQueue();
    expect(missed, isEmpty);
  });

  test(
    'an offer the system UI does not know keeps the in-app ringing',
    () async {
      build();
      await coordinator.start();
      signal.deliver('caller', 'offer', callId);
      await pumpEventQueue();
      expect(calls.isIncoming, isTrue);
      expect(calls.ringsInSystemUi, isFalse);
      expect(signal.sent, isEmpty);
    },
  );

  test('a foreground ring push fetches the pending call', () async {
    build();
    await coordinator.start();
    coordinator.onForegroundPush({
      'type': 'incoming_call',
      'callId': callId,
      'conversationId': 'c',
      'v': '1',
    });
    coordinator.onForegroundPush({'type': 'message', 'conversationId': 'c'});
    await pumpEventQueue();
    expect(signal.hub, ['RequestPendingCalls']);
  });

  group('ringIdFor', () {
    test('a UUID call id is its own system id', () {
      expect(ringIdFor(callId.toUpperCase()), callId);
    });

    test('other ids map to the UUIDv5 AppDelegate.swift computes', () {
      // Python: uuid.uuid5(uuid.NAMESPACE_URL, 'call-42')
      expect(ringIdFor('call-42'), '420e59c3-4fa9-5ecb-a3f3-b87d1e01ceb2');
    });
  });

  group('IncomingRing.fromPush', () {
    test('parses the ring push data keys', () {
      final ring = IncomingRing.fromPush({
        'type': 'incoming_call',
        'callId': callId,
        'conversationId': 'conv',
        'v': '1',
      });
      expect(ring?.callId, callId);
      expect(ring?.conversationId, 'conv');
    });

    test('rejects other types and missing or oversized ids', () {
      expect(
        IncomingRing.fromPush({'type': 'message', 'callId': callId}),
        isNull,
      );
      expect(IncomingRing.fromPush({'type': 'incoming_call'}), isNull);
      expect(
        IncomingRing.fromPush({'type': 'incoming_call', 'callId': 'x' * 65}),
        isNull,
      );
      expect(
        IncomingRing.fromPush({
          'type': 'call_cancelled',
          'callId': callId,
        }, type: ringPushCancelled)?.callId,
        callId,
      );
    });
  });
}
