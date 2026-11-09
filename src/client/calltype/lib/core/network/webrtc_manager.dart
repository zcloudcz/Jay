import 'dart:async';
import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:calltype_core/network/api_client.dart';
import 'signalr_client.dart';

enum CallState { idle, ringing, connecting, connected, ended }

/// Why a call failed. A code rather than text: this class has no BuildContext,
/// so the call screen maps it to a localized message.
enum CallError {
  connectionFailed,
  noAnswer,
  cannotStart,
  cannotAccept,
  userOffline,
  // H2: the hub rejected a BUSINESS offer outright (W2-F fail-closed rule /
  // group membership check). Distinct from the other errors above — no call
  // ever happened, so no CallReport is emitted for either of these.
  auditorUnavailable,
  notABusinessMember,
  // Call ringing spec R7: the callee declined (also from the lock screen
  // before the offer reached their app).
  declined,
}

class _CancelledCall implements Exception {}

/// One business call the app should archive as a `call-event` group message
/// when it ends (H2). Plain data — no JSON/transport knowledge here, that is
/// the sending listener's job. Never emitted for an anonymous call.
class CallReport {
  const CallReport({
    required this.callId,
    required this.businessGroupId,
    required this.role,
    required this.peerDeviceId,
    required this.startedAt,
    required this.endedAt,
    required this.media,
    required this.outcome,
  });
  final String callId;
  final String businessGroupId;
  final String role; // 'caller' | 'callee'
  final String peerDeviceId;
  final DateTime startedAt;
  final DateTime endedAt;
  final String media; // 'audio' | 'video'
  final String outcome; // 'completed' | 'missed' | 'rejected' | 'failed' | 'unavailable'
}

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
          _error = CallError.connectionFailed;
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

  /// The id of the current call (outgoing or incoming), null when idle.
  String? get callId => _callId;

  /// Caller side: the server reported that the callee's phone is ringing
  /// through CallKit / a full-screen notification (call ringing spec R5).
  bool _remoteRinging = false;
  bool get isRemoteRinging => _remoteRinging;

  /// Incoming calls that ring in the system UI (CallKit / Android full-screen
  /// notification) instead of the in-app ringing screen; lowercase ids.
  final _systemCalls = <String>{};
  final _finishedCalls = <String>{};
  // H2: business-call bookkeeping, so a CallReport can be built when the
  // call ends. Null for an anonymous call throughout.
  String? _businessGroupId;
  String? get businessGroupId => _businessGroupId;
  String? _callRole; // 'caller' | 'callee'
  DateTime? _callStartedAt;
  bool _callConnectedOnce = false;
  final _callReports = StreamController<CallReport>.broadcast();
  Stream<CallReport> get callReports => _callReports.stream;
  bool get isIncoming => _offer != null && _state == CallState.ringing;

  /// The current incoming call rings in the system UI, so the app must not
  /// show its own ringing screen / notification for it.
  bool get ringsInSystemUi =>
      isIncoming && _systemCalls.contains(_callId?.toLowerCase());

  /// Marks [callId] as ringing in the system UI (spec section 2: an offer for
  /// a call that CallKit already reported takes the accept path, not the
  /// in-app ringing UI). May be called before the offer arrives.
  void markSystemCall(String callId) {
    if (_systemCalls.add(callId.toLowerCase())) {
      if (_systemCalls.length > 16) _systemCalls.remove(_systemCalls.first);
      notifyListeners();
    }
  }

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
  CallError? _error;
  CallError? get error => _error;
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
        _error = CallError.noAnswer;
        unawaited(endCall());
      }
    });
  }

  Future<void> startCall(
    String targetDeviceId, {
    bool video = false,
    String? businessGroupId,
  }) async {
    if (_disposed || _state != CallState.idle && _state != CallState.ended) {
      return;
    }
    final generation = ++_generation;
    _error = null;
    _remoteDeviceId = targetDeviceId;
    _callId = const Uuid().v4();
    _remoteRinging = false;
    _isVideo = video;
    _businessGroupId = businessGroupId;
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
      // Only reached once the hub accepted the offer — a business rejection
      // (auditor_unavailable / not_a_business_member) throws out of the line
      // above, so no report is ever built for a call that never happened.
      _callRole = 'caller';
      _callStartedAt = DateTime.now();
      await _sendBufferedIce(generation);
    } on _CancelledCall {
      return;
    } catch (e) {
      if (!_active(generation)) return;
      final message = e.toString();
      if (businessGroupId != null && message.contains('auditor_unavailable')) {
        _error = CallError.auditorUnavailable;
      } else if (businessGroupId != null &&
          message.contains('not_a_business_member')) {
        _error = CallError.notABusinessMember;
      } else {
        _error = CallError.cannotStart;
      }
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
      _error = CallError.cannotAccept;
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
          _callConnectedOnce = true;
          notifyListeners();
        } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
          _error = CallError.connectionFailed;
          unawaited(_cleanup());
        }
      };
      media = await _mediaFactory({
        // Explicit constraints, not `true` — some platforms (notably web)
        // don't turn on echo cancellation by default, which is the acoustic
        // echo/feedback loop reported in beta (speaker -> mic -> back to
        // remote peer). All three are supported by every getUserMedia
        // backend flutter_webrtc targets.
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        // Without a size hint browsers and phones capture at the camera's
        // native resolution (often 720p/1080p), which stutters on mobile
        // uplinks and over a TURN relay (beta feedback 2026-09-18: "video is
        // choppy"). `ideal` is a preference, not a requirement, so a camera
        // that cannot do it still opens.
        'video': video
            ? {
                'facingMode': 'user',
                'width': {'ideal': 640},
                'height': {'ideal': 480},
                'frameRate': {'ideal': 24},
              }
            : false,
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
    // Every signal of a business call (offer, ice, hangup, answer) carries
    // the same businessGroupId, on both sides — see H1 for why this must be
    // a separate hub method rather than a 4th CallSignal argument.
    return _signalR.sendCallSignal(
      target,
      type,
      jsonEncode({'v': 1, 'callId': id, 'payload': payload}),
      businessGroupId: _businessGroupId,
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
      // The relayed event carries businessGroupId on the outer envelope
      // (never inside the encrypted-by-convention SDP payload) — null for an
      // anonymous call. This is what the answer/ice/hangup we send back use.
      final groupId = data['businessGroupId'];
      _businessGroupId = groupId is String ? groupId : null;
      _callRole = 'callee';
      _callStartedAt = DateTime.now();
      _callConnectedOnce = false;
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
        // R7: a decline from the callee's lock screen (or its in-app decline
        // button) carries the payload "declined".
        if (payload == 'declined' &&
            _offer == null &&
            _state == CallState.ringing) {
          _error = CallError.declined;
        }
        await _cleanup();
      case 'ringing':
        // R5: the callee is offline but its phone rings through a VoIP / ring
        // push. Keep ringing until answer, hangup or the 45 s timeout.
        if (_offer == null && _state == CallState.ringing && !_remoteRinging) {
          _remoteRinging = true;
          notifyListeners();
        }
      case 'cancelled':
        // R6: the caller gave up before this device received the offer.
        if (_offer != null && _state == CallState.ringing) {
          await _cleanup();
        }
      case 'unavailable':
        // Server-generated reply to our offer: the callee has no live
        // connection, so ringing on would only end in the 45 s timeout.
        // Only meaningful for the caller while still ringing.
        if (_offer == null && _state == CallState.ringing) {
          _error = CallError.userOffline;
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
    // An unanswered incoming call is declined (R7 payload), so the caller can
    // tell "declined" apart from a hang-up.
    final reason = isIncoming ? 'declined' : '';
    // Detach immediately; slow network signalling must not keep media active.
    final cleanup = _cleanup();
    if (target != null) {
      try {
        await _sendSignal(target, 'hangup', reason, callId: callId);
      } catch (_) {}
    }
    await cleanup;
  }

  /// Mute from the system call UI (CallKit / Android call notification).
  void setMuted(bool muted) {
    if (_isMuted != muted) toggleMute();
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

  /// H2: builds and emits the one [CallReport] for this call, if it was a
  /// business call that actually started (offer sent and accepted, or offer
  /// received). Must run before the fields it reads are cleared below.
  void _emitReportIfNeeded() {
    final groupId = _businessGroupId;
    final peer = _remoteDeviceId;
    final callId = _callId;
    final startedAt = _callStartedAt;
    final role = _callRole;
    if (groupId == null ||
        peer == null ||
        callId == null ||
        startedAt == null ||
        role == null) {
      return;
    }
    _callReports.add(
      CallReport(
        callId: callId,
        businessGroupId: groupId,
        role: role,
        peerDeviceId: peer,
        startedAt: startedAt,
        endedAt: DateTime.now(),
        media: _isVideo ? 'video' : 'audio',
        outcome: _deriveOutcome(),
      ),
    );
  }

  String _deriveOutcome() {
    if (_callConnectedOnce) return 'completed';
    switch (_error) {
      case CallError.noAnswer:
        return 'missed';
      case CallError.userOffline:
        return 'unavailable';
      case CallError.connectionFailed:
      case CallError.cannotStart:
      case CallError.cannotAccept:
        return 'failed';
      default:
        // Hung up by either side before connecting, with no recorded error:
        // the callee declined, or the caller gave up while still ringing.
        return 'rejected';
    }
  }

  Future<void> _cleanup() async {
    ++_generation;
    _timeout?.cancel();
    _emitReportIfNeeded();
    _state = CallState.ended;
    _offer = null;
    _remoteDescriptionSet = false;
    _localDescriptionSent = false;
    _earlyIce.clear();
    _localIce.clear();
    _remoteDeviceId = null;
    _businessGroupId = null;
    _callRole = null;
    _callStartedAt = null;
    _callConnectedOnce = false;
    final completedId = _callId;
    if (completedId != null) {
      _finishedCalls.add(completedId);
      if (_finishedCalls.length > 32) {
        _finishedCalls.remove(_finishedCalls.first);
      }
    }
    _callId = null;
    _remoteRinging = false;
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
    _callReports.close();
    super.dispose();
  }
}
