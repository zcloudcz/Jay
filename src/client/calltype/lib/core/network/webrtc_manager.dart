import 'dart:async';
import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'api_client.dart';
import 'signalr_client.dart';

enum CallState { idle, ringing, connecting, connected, ended }

class _CancelledCall implements Exception {}

class WebRTCManager extends ChangeNotifier {
  WebRTCManager({
    required SignalRClient signalRClient,
    required ApiClient apiClient,
    required String myDeviceId,
    // Test-only: forces ICE relay so I03 can prove a relay candidate was
    // actually selected. Never enabled in production call setup.
    this.forceIceRelay = false,
    Future<RTCPeerConnection> Function(Map<String, dynamic>)? peerFactory,
    Future<MediaStream> Function(Map<String, dynamic>)? mediaFactory,
    RTCVideoRenderer Function()? rendererFactory,
  }) : _signalR = signalRClient,
       _api = apiClient,
       _peerFactory = peerFactory ?? ((config) => createPeerConnection(config)),
       _mediaFactory =
           mediaFactory ??
           ((config) => navigator.mediaDevices.getUserMedia(config)),
       _rendererFactory = rendererFactory ?? RTCVideoRenderer.new {
    _subscription = _signalR.onCallSignal.listen((data) {
      final generation = _generation;
      _signals = _signals.then((_) => _handleSignal(data)).catchError((
        Object _,
      ) async {
        if (generation == _generation && !_disposed) {
          _error = 'Call connection failed.';
          await _cleanup();
        }
      });
    });
  }
  final SignalRClient _signalR;
  final ApiClient _api;
  /// Diagnostic switch (Settings → Diagnostics): when true, new calls use
  /// `iceTransportPolicy: relay`, so media can only flow through TURN. Used to
  /// prove the TURN provider really relays audio/video. Deliberately kept in
  /// memory only — it resets on restart so nobody stays stuck on the slower,
  /// metered relay path by accident. Applies to the NEXT call, not a live one.
  bool forceIceRelay;

  void setForceIceRelay(bool value) {
    if (forceIceRelay == value) return;
    forceIceRelay = value;
    notifyListeners();
  }
  final Future<RTCPeerConnection> Function(Map<String, dynamic>) _peerFactory;
  final Future<MediaStream> Function(Map<String, dynamic>) _mediaFactory;
  final RTCVideoRenderer Function() _rendererFactory;
  late StreamSubscription<Map<String, dynamic>> _subscription;
  Future<void> _signals = Future.value();
  RTCPeerConnection? _peer;
  MediaStream? _local;
  RTCVideoRenderer? localRenderer;
  RTCVideoRenderer? remoteRenderer;
  final _earlyIce = <RTCIceCandidate>[];
  final _localIce = <RTCIceCandidate>[];
  bool _remoteDescriptionSet = false;
  bool _localDescriptionSent = false;
  bool _disposed = false;
  int _generation = 0;
  Timer? _timeout;
  CallState _state = CallState.idle;
  CallState get state => _state;
  String? _remoteDeviceId;
  String? get remoteDeviceId => _remoteDeviceId;
  String? _offer;
  String? _callId;
  final _finishedCalls = <String>{};
  bool get isIncoming => _offer != null && _state == CallState.ringing;
  bool _isMuted = false;
  bool get isMuted => _isMuted;

  /// Remote media stream, kept so the speaker toggle can silence incoming
  /// audio without touching the peer connection.
  MediaStream? _remote;
  bool _isSpeakerMuted = false;
  bool get isSpeakerMuted => _isSpeakerMuted;
  bool _isCameraOff = false;
  bool get isCameraOff => _isCameraOff;
  bool _isVideo = false;
  bool get isVideo => _isVideo;
  String? _error;
  String? get error => _error;
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  bool _active(int generation) => !_disposed && generation == _generation;
  void _check(int generation) {
    if (!_active(generation)) throw _CancelledCall();
  }

  void _armTimeout() {
    _timeout?.cancel();
    final generation = _generation;
    _timeout = Timer(const Duration(seconds: 45), () {
      if (_active(generation) && _state != CallState.connected) {
        _error = 'No answer or connection timed out.';
        unawaited(endCall());
      }
    });
  }

  Future<void> startCall(String targetDeviceId, {bool video = false}) async {
    if (_disposed || _state != CallState.idle && _state != CallState.ended) {
      return;
    }
    final generation = ++_generation;
    _error = null;
    _remoteDeviceId = targetDeviceId;
    _callId = const Uuid().v4();
    _isVideo = video;
    _state = CallState.connecting;
    notifyListeners();
    _armTimeout();
    try {
      await _prepare(video, generation);
      _check(generation);
      final peer = _peer!;
      final offer = await peer.createOffer({});
      _check(generation);
      await peer.setLocalDescription(offer);
      _check(generation);
      // Set this before sending; the remote answer can beat invoke completion.
      _state = CallState.ringing;
      notifyListeners();
      await _sendSignal(targetDeviceId, 'offer', offer.sdp!);
      _check(generation);
      await _sendBufferedIce(generation);
    } on _CancelledCall {
      return;
    } catch (_) {
      if (!_active(generation)) return;
      _error =
          'Cannot start call. Check connection and microphone/camera permissions.';
      await _cleanup();
      rethrow;
    }
  }

  Future<void> acceptCall() async {
    if (isIncoming) {
      await answerCall(_remoteDeviceId!, _offer!, video: _isVideo);
    }
  }

  Future<void> answerCall(
    String callerDeviceId,
    String offerSdp, {
    bool video = false,
  }) async {
    if (_remoteDeviceId != callerDeviceId || !isIncoming) return;
    final generation = _generation;
    _state = CallState.connecting;
    _offer = null;
    notifyListeners();
    try {
      await _prepare(video, generation);
      _check(generation);
      final peer = _peer!;
      await peer.setRemoteDescription(RTCSessionDescription(offerSdp, 'offer'));
      _check(generation);
      await _flushIce(generation);
      _check(generation);
      final answer = await peer.createAnswer({});
      _check(generation);
      await peer.setLocalDescription(answer);
      _check(generation);
      await _sendSignal(callerDeviceId, 'answer', answer.sdp!);
      _check(generation);
      await _sendBufferedIce(generation);
    } on _CancelledCall {
      return;
    } catch (_) {
      if (!_active(generation)) return;
      _error = 'Cannot accept call. Check microphone/camera permissions.';
      await endCall();
    }
  }

  Future<void> _prepare(bool video, int generation) async {
    RTCPeerConnection? peer;
    MediaStream? media;
    RTCVideoRenderer? localVideo;
    RTCVideoRenderer? remoteVideo;
    var published = false;
    try {
      final credentials = await _api.getTurnCredentials(_signalR.deviceId);
      _check(generation);
      final servers = <Map<String, dynamic>>[];
      final urls = credentials['urls'];
      if (urls is List && urls.isNotEmpty ||
          urls is String && urls.isNotEmpty) {
        servers.add({
          'urls': urls,
          'username': credentials['username'],
          'credential': credentials['credential'],
        });
      }
      final stun = credentials['stunUrls'];
      if (stun is List && stun.isNotEmpty) servers.add({'urls': stun});
      localVideo = _rendererFactory();
      remoteVideo = _rendererFactory();
      await localVideo.initialize();
      _check(generation);
      await remoteVideo.initialize();
      _check(generation);
      peer = await _peerFactory({
        'iceServers': servers,
        'sdpSemantics': 'unified-plan',
        if (forceIceRelay) 'iceTransportPolicy': 'relay',
      });
      _check(generation);
      peer.onIceCandidate = (candidate) {
        if (!_active(generation) || candidate.candidate == null) return;
        if (!_localDescriptionSent) {
          if (_localIce.length < 256) _localIce.add(candidate);
        } else {
          unawaited(_sendIce(candidate, generation));
        }
      };
      peer.onTrack = (event) {
        if (_active(generation) && event.streams.isNotEmpty) {
          _remote = event.streams.first;
          remoteRenderer?.srcObject = _remote;
          // Tracks can arrive after the user already tapped "speaker off".
          _applySpeakerMute();
        }
      };
      peer.onIceConnectionState = (state) {
        if (!_active(generation)) return;
        if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
            state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
          _timeout?.cancel();
          _state = CallState.connected;
          notifyListeners();
        } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
          _error = 'Call connection failed.';
          unawaited(_cleanup());
        }
      };
      media = await _mediaFactory({
        'audio': true,
        'video': video ? {'facingMode': 'user'} : false,
      });
      _check(generation);
      for (final track in media.getTracks()) {
        await peer.addTrack(track, media);
        _check(generation);
      }
      localVideo.srcObject = media;
      _peer = peer;
      _local = media;
      localRenderer = localVideo;
      remoteRenderer = remoteVideo;
      published = true;
      notifyListeners();
    } finally {
      // Until publication these resources belong to this preparation, never to
      // a later call which may already be running after cancellation.
      if (!published) await _release(peer, media, localVideo, remoteVideo);
    }
  }

  Future<void> _sendSignal(
    String target,
    String type,
    String payload, {
    String? callId,
  }) {
    final id = callId ?? _callId;
    if (id == null) return Future.value();
    return _signalR.sendCallSignal(
      target,
      type,
      jsonEncode({'v': 1, 'callId': id, 'payload': payload}),
    );
  }

  Future<void> _sendIce(RTCIceCandidate candidate, int generation) async {
    if (!_active(generation) || _remoteDeviceId == null) return;
    try {
      await _sendSignal(
        _remoteDeviceId!,
        'ice-candidate',
        '${candidate.candidate}|${candidate.sdpMid}|${candidate.sdpMLineIndex}',
      );
    } catch (_) {}
  }

  Future<void> _sendBufferedIce(int generation) async {
    _check(generation);
    _localDescriptionSent = true;
    final pending = List<RTCIceCandidate>.of(_localIce);
    _localIce.clear();
    for (final candidate in pending) {
      _check(generation);
      await _sendIce(candidate, generation);
    }
  }

  Future<void> _flushIce(int generation) async {
    _check(generation);
    _remoteDescriptionSet = true;
    final pending = List<RTCIceCandidate>.of(_earlyIce);
    _earlyIce.clear();
    for (final candidate in pending) {
      _check(generation);
      await _peer!.addCandidate(candidate);
    }
  }

  Future<void> _handleSignal(Map<String, dynamic> data) async {
    if (_disposed) return;
    final sender = data['senderId'] as String?;
    final type = data['signalType'] as String?;
    final raw = data['payload'];
    if (raw is! String) return;
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (decoded is! Map ||
        decoded['v'] != 1 ||
        decoded['payload'] is! String ||
        decoded['callId'] is! String) {
      return;
    }
    final callId = decoded['callId'] as String;
    if (!RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(callId)) {
      return;
    }
    final payload = decoded['payload'] as String;
    if (sender == null || type == null) return;
    if (type == 'offer') {
      if (_finishedCalls.contains(callId) || callId == _callId) return;
      if (_state != CallState.idle && _state != CallState.ended) {
        await _sendSignal(sender, 'hangup', 'busy', callId: callId);
        return;
      }
      if (!payload.startsWith('v=0')) return;
      ++_generation;
      _remoteDeviceId = sender;
      _callId = callId;
      _offer = payload;
      _isVideo = payload.contains('m=video');
      _error = null;
      _state = CallState.ringing;
      _armTimeout();
      notifyListeners();
      return;
    }
    if (sender != _remoteDeviceId || callId != _callId) return;
    final generation = _generation;
    switch (type) {
      case 'answer':
        if (_peer != null && _offer == null && _state == CallState.ringing) {
          await _peer!.setRemoteDescription(
            RTCSessionDescription(payload, 'answer'),
          );
          _check(generation);
          await _flushIce(generation);
          _check(generation);
          if (_state != CallState.connected) _state = CallState.connecting;
          notifyListeners();
        }
      case 'ice-candidate':
        final parts = payload.split('|');
        if (parts.length != 3 || _earlyIce.length >= 256) return;
        final candidate = RTCIceCandidate(
          parts[0],
          parts[1] == 'null' ? null : parts[1],
          int.tryParse(parts[2]),
        );
        if (_remoteDescriptionSet && _peer != null) {
          await _peer!.addCandidate(candidate);
        } else {
          _earlyIce.add(candidate);
        }
      case 'hangup':
        await _cleanup();
      case 'unavailable':
        // Server-generated reply to our offer: the callee has no live
        // connection, so ringing on would only end in the 45 s timeout.
        // Only meaningful for the caller while still ringing.
        if (_offer == null && _state == CallState.ringing) {
          _error = 'User is offline right now. Try again later.';
          await _cleanup();
        }
    }
  }

  /// Redacted diagnostic for I03: which candidate type/protocol won, and for
  /// which call. Never returns SDP or IP addresses — those are personal
  /// network data and must not end up in logs or evidence files.
  Future<Map<String, String>?> getSelectedCandidateSummary() async {
    final peer = _peer;
    final callId = _callId;
    if (peer == null || callId == null) return null;
    final stats = await peer.getStats();
    final pair = stats.where(
      (r) =>
          r.type == 'candidate-pair' &&
          (r.values['state'] == 'succeeded' || r.values['nominated'] == true),
    );
    if (pair.isEmpty) return null;
    final localId = pair.first.values['localCandidateId'];
    final local = stats.where(
      (r) => r.type == 'local-candidate' && r.id == localId,
    );
    if (local.isEmpty) return null;
    final values = local.first.values;
    return {
      'type': '${values['candidateType']}',
      'protocol': '${values['protocol']}',
      'callId': callId,
    };
  }

  Future<void> endCall() async {
    final target = _remoteDeviceId;
    final callId = _callId;
    // Detach immediately; slow network signalling must not keep media active.
    final cleanup = _cleanup();
    if (target != null) {
      try {
        await _sendSignal(target, 'hangup', '', callId: callId);
      } catch (_) {}
    }
    await cleanup;
  }

  void toggleMute() {
    _isMuted = !_isMuted;
    for (final track in _local?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = !_isMuted;
    }
    notifyListeners();
  }

  void toggleCamera() {
    _isCameraOff = !_isCameraOff;
    for (final track in _local?.getVideoTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = !_isCameraOff;
    }
    notifyListeners();
  }

  /// Silences what we HEAR (the microphone toggle controls what we SEND).
  /// Disabling the remote audio tracks works identically on web and native,
  /// unlike per-platform speaker/volume APIs.
  void toggleSpeaker() {
    _isSpeakerMuted = !_isSpeakerMuted;
    _applySpeakerMute();
    notifyListeners();
  }

  void _applySpeakerMute() {
    for (final track in _remote?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = !_isSpeakerMuted;
    }
  }

  Future<void> _cleanup() async {
    ++_generation;
    _timeout?.cancel();
    _state = CallState.ended;
    _offer = null;
    _remoteDescriptionSet = false;
    _localDescriptionSent = false;
    _earlyIce.clear();
    _localIce.clear();
    _remoteDeviceId = null;
    final completedId = _callId;
    if (completedId != null) {
      _finishedCalls.add(completedId);
      if (_finishedCalls.length > 32) {
        _finishedCalls.remove(_finishedCalls.first);
      }
    }
    _callId = null;
    _isMuted = false;
    _isSpeakerMuted = false;
    _isCameraOff = false;
    _remote = null;
    final peer = _peer;
    _peer = null;
    final local = _local;
    _local = null;
    final localVideo = localRenderer;
    localRenderer = null;
    final remoteVideo = remoteRenderer;
    remoteRenderer = null;
    notifyListeners();
    await _release(peer, local, localVideo, remoteVideo);
  }

  Future<void> _release(
    RTCPeerConnection? peer,
    MediaStream? local,
    RTCVideoRenderer? localVideo,
    RTCVideoRenderer? remoteVideo,
  ) async {
    // Each native resource gets its cleanup attempt even if another fails.
    for (final track in local?.getTracks() ?? <MediaStreamTrack>[]) {
      try {
        await track.stop();
      } catch (_) {}
    }
    try {
      await local?.dispose();
    } catch (_) {}
    try {
      await peer?.close();
    } catch (_) {}
    for (final renderer in [localVideo, remoteVideo]) {
      try {
        renderer?.srcObject = null;
        await renderer?.dispose();
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _subscription.cancel();
    _timeout?.cancel();
    unawaited(_cleanup());
    super.dispose();
  }
}
