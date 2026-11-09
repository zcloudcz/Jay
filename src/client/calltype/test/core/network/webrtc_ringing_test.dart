// WebRTCManager and the call ringing signals (spec
// docs/superpowers/specs/2026-11-06-call-ringing.md, R5-R7).

import 'package:calltype/core/network/webrtc_manager.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_calls.dart';

const otherCall = '99887766-5544-4788-9900-aabbccddeeff';

void main() {
  late CallTestSignal signal;
  late WebRTCManager manager;

  setUp(() {
    signal = CallTestSignal(online: true);
    manager = testCallManager(signal);
  });

  tearDown(() async {
    manager.dispose();
    await signal.signals.close();
  });

  Future<String> startCall() async {
    await manager.startCall('callee');
    expect(manager.state, CallState.ringing);
    return manager.callId!;
  }

  test(
    'ringing keeps the caller ringing and marks the callee as rung',
    () async {
      final callId = await startCall();
      expect(manager.isRemoteRinging, isFalse);

      // A foreign call id changes nothing.
      signal.deliver('callee', 'ringing', otherCall);
      await pumpEventQueue();
      expect(manager.isRemoteRinging, isFalse);

      signal.deliver('callee', 'ringing', callId);
      await pumpEventQueue();
      expect(manager.isRemoteRinging, isTrue);
      expect(manager.state, CallState.ringing);
      expect(manager.error, isNull);

      await manager.endCall();
      expect(manager.isRemoteRinging, isFalse);
    },
  );

  test('ringing does not end the call early; the 45 s timeout still does', () {
    fakeAsync((async) {
      final local = CallTestSignal(online: true);
      final caller = testCallManager(local);
      caller.startCall('callee');
      async.flushMicrotasks();
      local.deliver('callee', 'ringing', caller.callId!);
      async.elapse(const Duration(seconds: 44));
      expect(caller.state, CallState.ringing);
      expect(caller.isRemoteRinging, isTrue);
      async.elapse(const Duration(seconds: 2));
      expect(caller.state, CallState.ended);
      expect(caller.error, CallError.noAnswer);
      caller.dispose();
    });
  });

  test('a declined hangup ends the call with the declined error', () async {
    final callId = await startCall();
    signal.deliver('callee', 'hangup', callId, 'declined');
    await pumpEventQueue();
    expect(manager.state, CallState.ended);
    expect(manager.error, CallError.declined);
  });

  test('a plain hangup while ringing is not reported as declined', () async {
    final callId = await startCall();
    signal.deliver('callee', 'hangup', callId, '');
    await pumpEventQueue();
    expect(manager.state, CallState.ended);
    expect(manager.error, isNull);
  });

  test('declining an incoming call sends the declined payload', () async {
    signal.deliver('caller', 'offer', otherCall);
    await pumpEventQueue();
    expect(manager.isIncoming, isTrue);
    await manager.endCall();
    expect(signal.sent, ['hangup declined']);
  });

  test('cancelled ends a ringing incoming call of that id only', () async {
    signal.deliver('caller', 'offer', otherCall);
    await pumpEventQueue();
    signal.deliver(
      'caller',
      'cancelled',
      '11223344-5566-4788-9900-aabbccddeeff',
      '',
    );
    await pumpEventQueue();
    expect(manager.isIncoming, isTrue);

    signal.deliver('caller', 'cancelled', otherCall, '');
    await pumpEventQueue();
    expect(manager.state, CallState.ended);
    expect(signal.sent, isEmpty);
  });

  test('a call marked for the system UI does not ring in the app', () async {
    manager.markSystemCall(otherCall.toUpperCase());
    signal.deliver('caller', 'offer', otherCall);
    await pumpEventQueue();
    expect(manager.isIncoming, isTrue);
    expect(manager.ringsInSystemUi, isTrue);

    await manager.acceptCall();
    expect(manager.ringsInSystemUi, isFalse);
    expect(signal.sent, contains('answer v=0'));
  });

  test('setMuted follows the system UI state', () async {
    await startCall();
    manager.setMuted(true);
    expect(manager.isMuted, isTrue);
    manager.setMuted(true);
    expect(manager.isMuted, isTrue);
    manager.setMuted(false);
    expect(manager.isMuted, isFalse);
  });
}
