import 'dart:async';
import 'dart:convert';

import 'package:calltype_core/network/api_client.dart';
import 'package:calltype/core/network/signalr_client.dart';
import 'package:calltype/core/network/webrtc_manager.dart';
import 'package:calltype/features/calls/call_ring.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Fakes for call tests that run a real [WebRTCManager] without WebRTC.

class CallTestApi extends ApiClient {
  CallTestApi() : super(baseUrl: 'http://unused');
  @override
  Future<Map<String, dynamic>> getTurnCredentials(String deviceId) async => {};
}

/// Hub fake: records outgoing call signals and the call ringing hub calls.
class CallTestSignal extends SignalRClient {
  CallTestSignal({this.online = false})
    : super(baseUrl: 'http://unused', deviceId: 'me');

  final signals = StreamController<Map<String, dynamic>>.broadcast();

  /// `type payload` of every CallSignal sent.
  final sent = <String>[];

  /// Hub methods of the call ringing contract, in call order.
  final hub = <String>[];
  bool online;
  int connects = 0;

  /// Runs when the app asks for its pending calls (the server delivers the
  /// offer then).
  void Function()? onRequestPendingCalls;

  @override
  bool get connected => online;

  @override
  Future<void> connect() async {
    connects++;
    online = true;
  }

  @override
  Future<void> requestPendingCalls() async {
    hub.add('RequestPendingCalls');
    onRequestPendingCalls?.call();
  }

  @override
  Future<void> declinePendingCall(String callId) async =>
      hub.add('DeclinePendingCall $callId');

  @override
  Stream<Map<String, dynamic>> get onCallSignal => signals.stream;

  @override
  Future<void> sendCallSignal(
    String peer,
    String type,
    String payload, {
    String? businessGroupId,
  }) async {
    final inner = (jsonDecode(payload) as Map)['payload'];
    sent.add('$type $inner'.trim());
  }

  /// Delivers a call signal from [sender] the way the hub relays it.
  void deliver(
    String sender,
    String type,
    String callId, [
    String payload = 'v=0',
  ]) => signals.add({
    'senderId': sender,
    'signalType': type,
    'payload': jsonEncode({'v': 1, 'callId': callId, 'payload': payload}),
  });
}

class CallTestRenderer implements RTCVideoRenderer {
  @override
  MediaStream? srcObject;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class CallTestTrack implements MediaStreamTrack {
  @override
  bool enabled = true;
  @override
  Future<void> stop() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class CallTestMedia implements MediaStream {
  final audio = [CallTestTrack()];
  @override
  List<MediaStreamTrack> getTracks() => audio;
  @override
  List<MediaStreamTrack> getAudioTracks() => audio;
  @override
  List<MediaStreamTrack> getVideoTracks() => const [];
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class CallTestSender implements RTCRtpSender {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class CallTestPeer implements RTCPeerConnection {
  bool closed = false;
  @override
  void Function(RTCIceCandidate)? onIceCandidate;
  @override
  void Function(RTCTrackEvent)? onTrack;
  @override
  void Function(RTCIceConnectionState)? onIceConnectionState;
  @override
  Future<RTCSessionDescription> createOffer([
    Map<String, dynamic>? constraints,
  ]) async => RTCSessionDescription('v=0', 'offer');
  @override
  Future<RTCSessionDescription> createAnswer([
    Map<String, dynamic>? constraints,
  ]) async => RTCSessionDescription('v=0', 'answer');
  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {}
  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {}
  @override
  Future<void> addCandidate(RTCIceCandidate candidate) async {}
  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  Future<RTCRtpSender> addTrack(
    MediaStreamTrack track, [
    MediaStream? stream,
  ]) async => CallTestSender();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A [WebRTCManager] wired to fakes; [peers] collects every peer it built.
WebRTCManager testCallManager(
  CallTestSignal signal, {
  List<CallTestPeer>? peers,
}) => WebRTCManager(
  signalRClient: signal,
  apiClient: CallTestApi(),
  myDeviceId: 'me',
  peerFactory: (_) async {
    final peer = CallTestPeer();
    peers?.add(peer);
    return peer;
  },
  rendererFactory: CallTestRenderer.new,
  mediaFactory: (_) async => CallTestMedia(),
);

/// The system call UI (CallKit / Android call screen) as a recorder.
class FakeRingPlatform implements CallRingPlatform {
  FakeRingPlatform({this.showsMissedOnTimeout = false});

  final controller = StreamController<RingEvent>.broadcast(sync: true);
  final shown = <String>[];
  final ended = <String>[];
  final connected = <String>[];
  List<ActiveRing> active = [];

  @override
  final bool showsMissedOnTimeout;

  @override
  Stream<RingEvent> get events => controller.stream;

  @override
  Future<void> showIncoming(IncomingRing ring) async => shown.add(ring.callId);

  @override
  Future<void> end(String callId) async => ended.add(callId);

  @override
  Future<void> setConnected(String callId) async => connected.add(callId);

  @override
  Future<List<ActiveRing>> activeCalls() async => active;
}
