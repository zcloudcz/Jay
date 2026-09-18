import 'dart:async';
import 'dart:convert';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:calltype/core/network/api_client.dart';
import 'package:calltype/core/network/signalr_client.dart';
import 'package:calltype/core/network/webrtc_manager.dart';

class TestApi extends ApiClient {
  TestApi() : super(baseUrl: 'http://unused');
  @override
  Future<Map<String, dynamic>> getTurnCredentials(String deviceId) async => {};
}

class TestSignal extends SignalRClient {
  TestSignal() : super(baseUrl: 'http://unused', deviceId: 'me');
  final signals = StreamController<Map<String, dynamic>>.broadcast();
  final sent = <String>[];
  final payloads = <String>[];
  Future<void> Function(String)? onSend;
  @override
  Stream<Map<String, dynamic>> get onCallSignal => signals.stream;
  @override
  Future<void> sendCallSignal(String peer, String type, String payload, {String? businessGroupId}) async {
    sent.add(type);
    payloads.add(payload);
    await onSend?.call(type);
  }
}

class TestRenderer implements RTCVideoRenderer {
  @override
  MediaStream? srcObject;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestTrack implements MediaStreamTrack {
  bool stopped = false;
  @override
  bool enabled = true;
  @override
  Future<void> stop() async {
    stopped = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestMedia implements MediaStream {
  TestMedia({List<TestTrack>? tracks}) : tracks = tracks ?? [];
  final List<TestTrack> tracks;
  bool disposed = false;
  @override
  List<MediaStreamTrack> getTracks() => tracks;
  @override
  Future<void> dispose() async {
    disposed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestMediaByKind implements MediaStream {
  TestMediaByKind({required this.audio, required this.video});
  final List<TestTrack> audio;
  final List<TestTrack> video;
  @override
  List<MediaStreamTrack> getTracks() => [...audio, ...video];
  @override
  List<MediaStreamTrack> getAudioTracks() => audio;
  @override
  List<MediaStreamTrack> getVideoTracks() => video;
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestRtpSender implements RTCRtpSender {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestPeer implements RTCPeerConnection {
  bool closed = false;
  bool answered = false;
  List<StatsReport>? stats;
  @override
  Future<List<StatsReport>> getStats([MediaStreamTrack? track]) async =>
      stats ?? [];
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
  Future<void> setLocalDescription(RTCSessionDescription description) async {
    onIceCandidate?.call(RTCIceCandidate('candidate', '0', 0));
  }

  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {
    answered = true;
  }

  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  Future<RTCRtpSender> addTrack(
    MediaStreamTrack track, [
    MediaStream? stream,
  ]) async => TestRtpSender();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'cancelled media preparation cannot revive call or leak acquired media',
    () async {
      final signal = TestSignal();
      final peer = TestPeer();
      final media = TestMedia();
      final requested = Completer<void>();
      final permission = Completer<MediaStream>();
      final manager = WebRTCManager(
        signalRClient: signal,
        apiClient: TestApi(),
        myDeviceId: 'me',
        peerFactory: (_) async => peer,
        rendererFactory: TestRenderer.new,
        mediaFactory: (_) {
          requested.complete();
          return permission.future;
        },
      );
      final starting = manager.startCall('other');
      await requested.future;
      await manager.endCall();
      permission.complete(media);
      await starting;
      expect(manager.state, CallState.ended);
      expect(media.disposed, isTrue);
      expect(peer.closed, isTrue);
      expect(signal.sent, isNot(contains('offer')));
      manager.dispose();
      await signal.signals.close();
    },
  );
  test(
    'offer precedes ICE and fast answer is accepted before send completes',
    () async {
      final signal = TestSignal();
      final peer = TestPeer();
      final manager = WebRTCManager(
        signalRClient: signal,
        apiClient: TestApi(),
        myDeviceId: 'me',
        peerFactory: (_) async => peer,
        rendererFactory: TestRenderer.new,
        mediaFactory: (_) async => TestMedia(),
      );
      signal.onSend = (type) async {
        if (type == 'offer') {
          signal.signals.add({
            'senderId': 'other',
            'signalType': 'answer',
            'payload': jsonEncode({
              'v': 1,
              'callId': (jsonDecode(signal.payloads.last) as Map)['callId'],
              'payload': 'v=0',
            }),
          });
          await Future<void>.delayed(Duration.zero);
        }
      };
      await manager.startCall('other');
      expect(peer.answered, isTrue);
      expect(signal.sent.take(2), ['offer', 'ice-candidate']);
      expect(manager.state, CallState.connecting);
      await manager.endCall();
      manager.dispose();
      await signal.signals.close();
    },
  );
  test(
    'late preparation from cancelled call cannot dispose replacement call',
    () async {
      final signal = TestSignal();
      final oldPeer = TestPeer();
      final newPeer = TestPeer();
      final requested = Completer<void>();
      final permission = Completer<MediaStream>();
      var peers = 0;
      var captures = 0;
      final manager = WebRTCManager(
        signalRClient: signal,
        apiClient: TestApi(),
        myDeviceId: 'me',
        peerFactory: (_) async => peers++ == 0 ? oldPeer : newPeer,
        rendererFactory: TestRenderer.new,
        mediaFactory: (_) {
          if (captures++ == 0) {
            requested.complete();
            return permission.future;
          }
          return Future.value(TestMedia());
        },
      );
      final first = manager.startCall('first');
      await requested.future;
      await manager.endCall();
      await manager.startCall('second');
      permission.complete(TestMedia());
      await first;
      expect(manager.remoteDeviceId, 'second');
      expect(manager.state, CallState.ringing);
      expect(oldPeer.closed, isTrue);
      expect(newPeer.closed, isFalse);
      oldPeer.onIceConnectionState?.call(
        RTCIceConnectionState.RTCIceConnectionStateFailed,
      );
      expect(manager.state, CallState.ringing);
      await manager.endCall();
      manager.dispose();
      await signal.signals.close();
    },
  );
  test('old same-peer hangup cannot end replacement call', () async {
    final signal = TestSignal();
    final manager = WebRTCManager(
      signalRClient: signal,
      apiClient: TestApi(),
      myDeviceId: 'me',
      peerFactory: (_) async => TestPeer(),
      rendererFactory: TestRenderer.new,
      mediaFactory: (_) async => TestMedia(),
    );
    await manager.startCall('other');
    await manager.endCall();
    final oldHangup = signal.payloads.last;
    await manager.startCall('other');
    final currentId = (jsonDecode(signal.payloads.last) as Map)['callId'];
    signal.signals.add({
      'senderId': 'other',
      'signalType': 'hangup',
      'payload': oldHangup,
    });
    await Future<void>.delayed(Duration.zero);
    expect(manager.state, CallState.ringing);
    signal.signals.add({
      'senderId': 'other',
      'signalType': 'hangup',
      'payload': jsonEncode({'v': 1, 'callId': currentId, 'payload': ''}),
    });
    await Future<void>.delayed(Duration.zero);
    expect(manager.state, CallState.ended);
    manager.dispose();
    await signal.signals.close();
  });
  test(
    'incoming call captures UUID and ignores legacy or retired offers',
    () async {
      final signal = TestSignal();
      final manager = WebRTCManager(
        signalRClient: signal,
        apiClient: TestApi(),
        myDeviceId: 'me',
        peerFactory: (_) async => TestPeer(),
        rendererFactory: TestRenderer.new,
        mediaFactory: (_) async => TestMedia(),
      );
      signal.signals.add({
        'senderId': 'other',
        'signalType': 'offer',
        'payload': 'v=0',
      });
      await Future<void>.delayed(Duration.zero);
      expect(manager.state, CallState.idle);
      const id = '11223344-5566-4788-9900-aabbccddeeff';
      final incoming = {
        'senderId': 'other',
        'signalType': 'offer',
        'payload': jsonEncode({'v': 1, 'callId': id, 'payload': 'v=0'}),
      };
      signal.signals.add(incoming);
      await Future<void>.delayed(Duration.zero);
      expect(manager.isIncoming, isTrue);
      await manager.acceptCall();
      expect(signal.sent.first, 'answer');
      expect((jsonDecode(signal.payloads.first) as Map)['callId'], id);
      await manager.endCall();
      signal.signals.add(incoming);
      await Future<void>.delayed(Duration.zero);
      expect(manager.state, CallState.ended);
      manager.dispose();
      await signal.signals.close();
    },
  );
  test('microphone permission denial closes peer and leaks nothing', () async {
    final signal = TestSignal();
    final peer = TestPeer();
    final manager = WebRTCManager(
      signalRClient: signal,
      apiClient: TestApi(),
      myDeviceId: 'me',
      peerFactory: (_) async => peer,
      rendererFactory: TestRenderer.new,
      mediaFactory: (_) async => throw Exception('NotAllowedError: microphone'),
    );
    await manager.startCall('other').catchError((_) {});
    expect(manager.state, CallState.ended);
    expect(peer.closed, isTrue);
    expect(manager.error, isNotNull);
    expect(signal.sent, isNot(contains('offer')));
    manager.dispose();
    await signal.signals.close();
  });
  test('camera permission denial closes peer and leaks nothing', () async {
    final signal = TestSignal();
    final peer = TestPeer();
    final manager = WebRTCManager(
      signalRClient: signal,
      apiClient: TestApi(),
      myDeviceId: 'me',
      peerFactory: (_) async => peer,
      rendererFactory: TestRenderer.new,
      mediaFactory: (_) async => throw Exception('NotAllowedError: camera'),
    );
    await manager.startCall('other', video: true).catchError((_) {});
    expect(manager.state, CallState.ended);
    expect(peer.closed, isTrue);
    manager.dispose();
    await signal.signals.close();
  });
  test(
    'connection drop mid-call closes peer and stops tracks, not just state',
    () async {
      final signal = TestSignal();
      final peer = TestPeer();
      final track = TestTrack();
      final media = TestMedia(tracks: [track]);
      final manager = WebRTCManager(
        signalRClient: signal,
        apiClient: TestApi(),
        myDeviceId: 'me',
        peerFactory: (_) async => peer,
        rendererFactory: TestRenderer.new,
        mediaFactory: (_) async => media,
      );
      await manager.startCall('other');
      peer.onIceConnectionState?.call(
        RTCIceConnectionState.RTCIceConnectionStateConnected,
      );
      expect(manager.state, CallState.connected);
      peer.onIceConnectionState?.call(
        RTCIceConnectionState.RTCIceConnectionStateFailed,
      );
      await Future<void>.delayed(Duration.zero);
      expect(manager.state, CallState.ended);
      expect(peer.closed, isTrue);
      expect(track.stopped, isTrue);
      expect(media.disposed, isTrue);
      manager.dispose();
      await signal.signals.close();
    },
  );
  test(
    'repeated call A to B then new call: first call cannot end the second',
    () async {
      final signal = TestSignal();
      final manager = WebRTCManager(
        signalRClient: signal,
        apiClient: TestApi(),
        myDeviceId: 'me',
        peerFactory: (_) async => TestPeer(),
        rendererFactory: TestRenderer.new,
        mediaFactory: (_) async => TestMedia(),
      );
      await manager.startCall('b');
      final firstCallId = (jsonDecode(signal.payloads.last) as Map)['callId'];
      await manager.endCall();
      await manager.startCall('b');
      expect(manager.state, CallState.ringing);
      // Late ICE from the ended first call must not touch the new call.
      signal.signals.add({
        'senderId': 'b',
        'signalType': 'ice-candidate',
        'payload': jsonEncode({
          'v': 1,
          'callId': firstCallId,
          'payload': 'cand|0|0',
        }),
      });
      await Future<void>.delayed(Duration.zero);
      expect(manager.state, CallState.ringing);
      await manager.endCall();
      manager.dispose();
      await signal.signals.close();
    },
  );
  test('offline callee: server "unavailable" ends ringing at once with a clear error', () async {
    final signal = TestSignal();
    final peer = TestPeer();
    final media = TestMedia(tracks: [TestTrack()]);
    final manager = WebRTCManager(
      signalRClient: signal,
      apiClient: TestApi(),
      myDeviceId: 'me',
      peerFactory: (_) async => peer,
      rendererFactory: TestRenderer.new,
      mediaFactory: (_) async => media,
    );
    await manager.startCall('other');
    expect(manager.state, CallState.ringing);
    final callId = (jsonDecode(signal.payloads.first) as Map)['callId'];

    // A stale/foreign callId must not be able to end this call.
    signal.signals.add({
      'senderId': 'other',
      'signalType': 'unavailable',
      'payload': jsonEncode({'v': 1, 'callId': '00000000-0000-4000-8000-000000000000', 'payload': 'v=0'}),
    });
    await Future<void>.delayed(Duration.zero);
    expect(manager.state, CallState.ringing);

    signal.signals.add({
      'senderId': 'other',
      'signalType': 'unavailable',
      'payload': jsonEncode({'v': 1, 'callId': callId, 'payload': 'v=0'}),
    });
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(manager.state, CallState.ended);
    expect(manager.error, CallError.userOffline);
    expect(peer.closed, isTrue); // resources released, not just a state flip
    expect(media.tracks.single.stopped, isTrue);
    manager.dispose();
    await signal.signals.close();
  });

  test('speaker toggle silences remote audio only, even for late tracks', () async {
    final peer = TestPeer();
    final localAudio = TestTrack();
    final manager = WebRTCManager(
      signalRClient: TestSignal(),
      apiClient: TestApi(),
      myDeviceId: 'me',
      peerFactory: (_) async => peer,
      rendererFactory: TestRenderer.new,
      mediaFactory: (_) async => TestMediaByKind(audio: [localAudio], video: []),
    );
    await manager.startCall('other');

    // Mute BEFORE the remote track arrives — it must still come up silenced.
    manager.toggleSpeaker();
    expect(manager.isSpeakerMuted, isTrue);
    final remoteAudio = TestTrack();
    final remoteVideo = TestTrack();
    peer.onTrack!(RTCTrackEvent(
      streams: [TestMediaByKind(audio: [remoteAudio], video: [remoteVideo])],
      track: remoteAudio,
    ));
    expect(remoteAudio.enabled, isFalse);
    expect(remoteVideo.enabled, isTrue);
    expect(localAudio.enabled, isTrue); // our microphone is a separate control

    manager.toggleSpeaker();
    expect(remoteAudio.enabled, isTrue);

    await manager.endCall();
    expect(manager.isSpeakerMuted, isFalse); // never carries into the next call
    manager.dispose();
  });

  test('runtime force-relay switch applies to the next call and notifies', () async {
    // Backs the Settings → Diagnostics toggle: flipping it must change the ICE
    // policy of the NEXT call without recreating the manager.
    Map<String, dynamic>? capturedConfig;
    final manager = WebRTCManager(
      signalRClient: TestSignal(),
      apiClient: TestApi(),
      myDeviceId: 'me',
      peerFactory: (config) async {
        capturedConfig = config;
        return TestPeer();
      },
      rendererFactory: TestRenderer.new,
      mediaFactory: (_) async => TestMedia(),
    );
    var notifications = 0;
    manager.addListener(() => notifications++);

    manager.setForceIceRelay(true);
    expect(notifications, 1);
    manager.setForceIceRelay(true); // no-op must not spam listeners
    expect(notifications, 1);

    await manager.startCall('other');
    expect(capturedConfig!['iceTransportPolicy'], 'relay');
    await manager.endCall();

    manager.setForceIceRelay(false);
    await manager.startCall('other');
    expect(capturedConfig!.containsKey('iceTransportPolicy'), isFalse);
    await manager.endCall();
    manager.dispose();
  });

  test(
    'forced ICE relay is off by default and opt-in sets transport policy',
    () async {
      final signal = TestSignal();
      Map<String, dynamic>? capturedConfig;
      final defaultManager = WebRTCManager(
        signalRClient: signal,
        apiClient: TestApi(),
        myDeviceId: 'me',
        peerFactory: (config) async {
          capturedConfig = config;
          return TestPeer();
        },
        rendererFactory: TestRenderer.new,
        mediaFactory: (_) async => TestMedia(),
      );
      await defaultManager.startCall('other');
      expect(capturedConfig!.containsKey('iceTransportPolicy'), isFalse);
      await defaultManager.endCall();
      defaultManager.dispose();

      final relaySignal = TestSignal();
      final relayManager = WebRTCManager(
        signalRClient: relaySignal,
        apiClient: TestApi(),
        myDeviceId: 'me',
        forceIceRelay: true,
        peerFactory: (config) async {
          capturedConfig = config;
          return TestPeer();
        },
        rendererFactory: TestRenderer.new,
        mediaFactory: (_) async => TestMedia(),
      );
      await relayManager.startCall('other');
      expect(capturedConfig!['iceTransportPolicy'], 'relay');
      await relayManager.endCall();
      relayManager.dispose();
      await signal.signals.close();
      await relaySignal.signals.close();
    },
  );
  test(
    'selected candidate pair summary is redacted to type/protocol/callId',
    () async {
      final signal = TestSignal();
      final peer = TestPeer();
      final manager = WebRTCManager(
        signalRClient: signal,
        apiClient: TestApi(),
        myDeviceId: 'me',
        peerFactory: (_) async => peer,
        rendererFactory: TestRenderer.new,
        mediaFactory: (_) async => TestMedia(),
      );
      await manager.startCall('other');
      peer.stats = [
        StatsReport('pair1', 'candidate-pair', 0, {
          'state': 'succeeded',
          'nominated': true,
          'localCandidateId': 'local1',
        }),
        StatsReport('local1', 'local-candidate', 0, {
          'candidateType': 'relay',
          'protocol': 'udp',
          'ip': '203.0.113.5',
        }),
      ];
      final callId = (jsonDecode(signal.payloads.last) as Map)['callId'];
      final summary = await manager.getSelectedCandidateSummary();
      expect(summary, {'type': 'relay', 'protocol': 'udp', 'callId': callId});
      // Never expose the raw candidate address/SDP through this API.
      expect(summary.toString(), isNot(contains('203.0.113.5')));
      await manager.endCall();
      manager.dispose();
      await signal.signals.close();
    },
  );
  test('mute and camera toggles only flip local track.enabled', () async {
    final signal = TestSignal();
    final audioTrack = TestTrack();
    final videoTrack = TestTrack();
    final manager = WebRTCManager(
      signalRClient: signal,
      apiClient: TestApi(),
      myDeviceId: 'me',
      peerFactory: (_) async => TestPeer(),
      rendererFactory: TestRenderer.new,
      mediaFactory: (_) async =>
          TestMediaByKind(audio: [audioTrack], video: [videoTrack]),
    );
    await manager.startCall('other', video: true);
    expect(manager.isMuted, isFalse);
    manager.toggleMute();
    expect(manager.isMuted, isTrue);
    expect(audioTrack.enabled, isFalse);
    expect(videoTrack.enabled, isTrue); // mute must not touch video
    manager.toggleCamera();
    expect(videoTrack.enabled, isFalse);
    expect(audioTrack.enabled, isFalse); // camera toggle must not touch audio
    await manager.endCall();
    manager.dispose();
    await signal.signals.close();
  });
  test('second incoming offer while busy is declined, not queued', () async {
    final signal = TestSignal();
    final manager = WebRTCManager(
      signalRClient: signal,
      apiClient: TestApi(),
      myDeviceId: 'me',
      peerFactory: (_) async => TestPeer(),
      rendererFactory: TestRenderer.new,
      mediaFactory: (_) async => TestMedia(),
    );
    await manager.startCall('other');
    signal.signals.add({
      'senderId': 'third',
      'signalType': 'offer',
      'payload': jsonEncode({
        'v': 1,
        'callId': '99887766-5544-4788-9900-aabbccddeeff',
        'payload': 'v=0',
      }),
    });
    await Future<void>.delayed(Duration.zero);
    // Declined via busy signal to the third party; own call state untouched.
    expect(signal.sent.last, 'hangup');
    expect(signal.payloads.last, contains('busy'));
    expect(manager.remoteDeviceId, 'other');
    await manager.endCall();
    manager.dispose();
    await signal.signals.close();
  });
  test('no-answer timeout ends the call and releases resources', () {
    fakeAsync((async) {
      final signal = TestSignal();
      final peer = TestPeer();
      final manager = WebRTCManager(
        signalRClient: signal,
        apiClient: TestApi(),
        myDeviceId: 'me',
        peerFactory: (_) async => peer,
        rendererFactory: TestRenderer.new,
        mediaFactory: (_) async => TestMedia(),
      );
      unawaited(manager.startCall('other'));
      async.flushMicrotasks();
      expect(manager.state, CallState.ringing);
      async.elapse(const Duration(seconds: 45));
      async.flushMicrotasks();
      expect(manager.state, CallState.ended);
      expect(peer.closed, isTrue);
      expect(manager.error, CallError.noAnswer);
      manager.dispose();
    });
  });
}
