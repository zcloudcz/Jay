import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'api_client.dart';
import 'signalr_client.dart';

/// Possible states of a voice/video call.
///
/// The state machine transitions are:
///   idle -> ringing (incoming offer or outgoing call initiated)
///   ringing -> connecting (answer sent/received)
///   connecting -> connected (ICE negotiation succeeded, media flowing)
///   any -> ended (hangup, error, or ICE failure)
///   ended -> idle (after cleanup)
enum CallState { idle, ringing, connecting, connected, ended }

/// Manages the full WebRTC peer connection lifecycle for voice/video calls.
///
/// Responsibilities:
///   - Creating and configuring [RTCPeerConnection] with ICE servers
///   - Capturing local media (audio, optionally video)
///   - Exchanging SDP offers/answers and ICE candidates via [SignalRClient]
///   - Tracking call state and exposing streams for UI rendering
///   - Fetching time-limited TURN credentials from the API
///
/// Extends [ChangeNotifier] so the call UI can rebuild reactively when
/// the call state, mute status, or camera status changes.
///
/// Usage:
///   1. Construct with SignalRClient, ApiClient, and local device ID
///   2. Call [startCall] to initiate an outgoing call
///   3. Or handle incoming calls via the SignalR onCallSignal stream
///   4. Call [endCall] to hang up and release resources
///   5. Dispose when the manager is no longer needed
class WebRTCManager extends ChangeNotifier {
  WebRTCManager({
    required SignalRClient signalRClient,
    required ApiClient apiClient,
    required String myDeviceId,
  })  : _signalR = signalRClient,
        _apiClient = apiClient,
        _myDeviceId = myDeviceId {
    // Listen for incoming WebRTC signaling messages (offers, answers,
    // ICE candidates, hangups) from the SignalR hub. This subscription
    // stays active for the lifetime of this manager so we can receive
    // calls at any time.
    _signalSubscription = _signalR.onCallSignal.listen(_handleSignal);
  }

  final SignalRClient _signalR;
  final ApiClient _apiClient;
  final String _myDeviceId;

  StreamSubscription<Map<String, dynamic>>? _signalSubscription;

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;

  /// Video renderers for displaying local and remote video feeds.
  /// Initialized lazily when a call starts, disposed on cleanup.
  /// The UI should use these with [RTCVideoView] widgets.
  RTCVideoRenderer? localRenderer;
  RTCVideoRenderer? remoteRenderer;

  CallState _state = CallState.idle;
  bool _isMuted = false;
  bool _isVideo = false;
  String? _remoteDeviceId;

  /// Current state of the call — drives the UI layout and controls.
  CallState get state => _state;

  /// Whether the local microphone is muted.
  bool get isMuted => _isMuted;

  /// Whether video is active (as opposed to audio-only).
  bool get isVideo => _isVideo;

  /// The device ID of the remote call participant, if any.
  String? get remoteDeviceId => _remoteDeviceId;

  /// Initiates an outgoing call to the target device.
  ///
  /// Creates a peer connection, captures local media, generates an SDP
  /// offer, and sends it to the target via SignalR. The call transitions
  /// to [CallState.ringing] while waiting for the remote answer.
  ///
  /// [targetDeviceId] is the remote device's UUID.
  /// [video] controls whether video tracks are captured (default: false
  /// for voice-only calls).
  Future<void> startCall(String targetDeviceId, {bool video = false}) async {
    if (_state != CallState.idle) return;

    _remoteDeviceId = targetDeviceId;
    _isVideo = video;

    await _initRenderers();
    await _createPeerConnection(targetDeviceId);
    await _captureLocalMedia(video);

    // Add local tracks to the peer connection so the remote side receives
    // our audio/video. Each track is added individually rather than using
    // addStream (deprecated in the WebRTC spec).
    for (final track in _localStream!.getTracks()) {
      await _peerConnection!.addTrack(track, _localStream!);
    }

    // Generate the SDP offer. Empty constraints map uses default settings
    // which include both audio and video directions.
    final offer = await _peerConnection!.createOffer({});
    await _peerConnection!.setLocalDescription(offer);

    // Send the offer to the remote device via the signaling channel.
    // The remote side will receive this in _handleSignal and can choose
    // to accept (answer) or reject (hangup).
    await _signalR.sendCallSignal(
      targetDeviceId,
      'offer',
      '${offer.sdp}',
    );

    _state = CallState.ringing;
    notifyListeners();
  }

  /// Answers an incoming call from a remote device.
  ///
  /// Called by the UI when the user accepts an incoming call. Sets up the
  /// peer connection, captures local media, applies the remote offer SDP,
  /// and sends back an answer SDP.
  ///
  /// [callerDeviceId] is the device that initiated the call.
  /// [offerSdp] is the SDP string from the incoming offer.
  /// [video] controls whether to capture video (should match the offer).
  Future<void> answerCall(
    String callerDeviceId,
    String offerSdp, {
    bool video = false,
  }) async {
    _remoteDeviceId = callerDeviceId;
    _isVideo = video;

    await _initRenderers();
    await _createPeerConnection(callerDeviceId);
    await _captureLocalMedia(video);

    for (final track in _localStream!.getTracks()) {
      await _peerConnection!.addTrack(track, _localStream!);
    }

    // Apply the caller's offer as the remote description so the peer
    // connection knows what media capabilities the caller has.
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(offerSdp, 'offer'),
    );

    // Generate and send our answer SDP back to the caller.
    final answer = await _peerConnection!.createAnswer({});
    await _peerConnection!.setLocalDescription(answer);

    await _signalR.sendCallSignal(
      callerDeviceId,
      'answer',
      '${answer.sdp}',
    );

    _state = CallState.connecting;
    notifyListeners();
  }

  /// Ends the current call and notifies the remote side.
  ///
  /// Sends a hangup signal so the remote peer can clean up its resources
  /// too, then releases all local resources (streams, renderers, connection).
  Future<void> endCall() async {
    if (_remoteDeviceId != null) {
      // Best-effort hangup notification — don't fail the cleanup if
      // the SignalR send fails (e.g. already disconnected).
      try {
        await _signalR.sendCallSignal(_remoteDeviceId!, 'hangup', '');
      } catch (_) {
        // Intentionally ignored — cleanup must proceed regardless.
      }
    }
    await _cleanup();
  }

  /// Toggles the local microphone mute state.
  ///
  /// Disabling audio tracks stops sending audio to the remote peer
  /// without tearing down the connection. The track stays in the
  /// peer connection so it can be re-enabled instantly.
  void toggleMute() {
    if (_localStream == null) return;

    _isMuted = !_isMuted;
    for (final track in _localStream!.getAudioTracks()) {
      track.enabled = !_isMuted;
    }
    notifyListeners();
  }

  /// Toggles the local camera on/off.
  ///
  /// Similar to mute — disables video tracks without renegotiation.
  /// The remote side will see a frozen last frame or black screen
  /// depending on the platform's WebRTC implementation.
  void toggleCamera() {
    if (_localStream == null) return;

    final videoTracks = _localStream!.getVideoTracks();
    if (videoTracks.isEmpty) return;

    // Toggle the enabled state of all video tracks. Most devices have
    // exactly one video track, but we handle multiple for robustness.
    for (final track in videoTracks) {
      track.enabled = !track.enabled;
    }
    notifyListeners();
  }

  /// Creates an [RTCPeerConnection] configured with STUN and TURN servers.
  ///
  /// STUN is used for NAT traversal in the common case (symmetric NAT).
  /// TURN is the fallback relay when direct peer-to-peer fails. TURN
  /// credentials are time-limited and fetched from our API, which delegates
  /// to the DeskShare TURN server.
  ///
  /// [targetDeviceId] is used to fetch TURN credentials (the server may
  /// use it for rate limiting or logging).
  Future<void> _createPeerConnection(String targetDeviceId) async {
    // Fetch time-limited TURN credentials from the backend.
    // The backend generates HMAC-SHA1 credentials compatible with the
    // DeskShare.Turn server from RemoteDesktopNet.
    Map<String, dynamic>? turnCreds;
    try {
      turnCreds = await _apiClient.getTurnCredentials(_myDeviceId);
    } catch (_) {
      // If TURN credential fetch fails, we still try with STUN only.
      // Direct connections will work in most network configurations;
      // TURN is only needed behind restrictive firewalls.
    }

    // ICE server configuration: STUN for candidate gathering, TURN as
    // relay fallback. The STUN/TURN servers are provided by DeskShare.Stun
    // and DeskShare.Turn from the RemoteDesktopNet project.
    //
    // Default STUN port 3478 matches the DeskShare.Stun server default.
    // TURN URLs and credentials are fetched from the API because:
    //   1. TURN credentials are time-limited (HMAC-SHA1 based)
    //   2. Server URLs may differ between environments (dev/staging/prod)
    //   3. The API may return multiple TURN URLs (UDP + TCP + TLS)
    final iceServers = <Map<String, dynamic>>[
      // STUN is unauthenticated — no credentials needed. It only helps
      // discover the device's public IP and port mapping.
      {'urls': 'stun:stun.zmessanger.com:3478'},
    ];

    // Use server-provided TURN configuration when available.
    // The /turn/credentials endpoint returns:
    //   - urls: TURN server URL(s) matching DeskShare.Turn's listener
    //   - username: time-stamped username (expires per TTL)
    //   - credential: HMAC-SHA1 signature of the username
    if (turnCreds != null) {
      final turnUrls = turnCreds['urls'];
      final username = turnCreds['username']?.toString() ?? '';
      final credential = turnCreds['credential']?.toString() ?? '';

      if (turnUrls is List) {
        // Server returned multiple TURN URLs (e.g. UDP, TCP, TLS variants).
        // Add each as a separate ICE server entry so the browser/platform
        // can try all transport types during connectivity checks.
        for (final url in turnUrls) {
          iceServers.add({
            'urls': url.toString(),
            'username': username,
            'credential': credential,
          });
        }
      } else if (turnUrls is String) {
        // Single TURN URL — common for simple deployments.
        iceServers.add({
          'urls': turnUrls,
          'username': username,
          'credential': credential,
        });
      } else {
        // Fallback: API didn't return a urls field, use default TURN address.
        // Port 3479 is the DeskShare.Turn default.
        iceServers.add({
          'urls': 'turn:turn.zmessanger.com:3479',
          'username': username,
          'credential': credential,
        });
      }
    }

    _peerConnection = await createPeerConnection(
      {
        'iceServers': iceServers,
        // Unified Plan is the modern SDP semantics (replaces Plan B).
        // Required for proper transceiver-based negotiation.
        'sdpSemantics': 'unified-plan',
      },
    );

    // -- Event handlers -------------------------------------------------------

    // Forward ICE candidates to the remote peer via SignalR.
    // Each candidate represents a possible network path; the remote side
    // needs all of them to find a working connection route.
    _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
      if (_remoteDeviceId == null) return;

      // Pack candidate data into a pipe-delimited string for transport.
      // Format: candidate|sdpMid|sdpMLineIndex
      final payload =
          '${candidate.candidate}|${candidate.sdpMid}|${candidate.sdpMLineIndex}';
      _signalR.sendCallSignal(_remoteDeviceId!, 'ice-candidate', payload);
    };

    // Remote media track received — this fires when the remote peer's
    // audio/video starts arriving. We capture the stream for rendering.
    _peerConnection!.onTrack = (RTCTrackEvent event) {
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams[0];
        remoteRenderer?.srcObject = _remoteStream;

        _state = CallState.connected;
        notifyListeners();
      }
    };

    // Monitor ICE connection state for failures and disconnections.
    // This is the primary way we detect when a call drops unexpectedly
    // (network change, peer crash, etc.).
    _peerConnection!.onIceConnectionState = (RTCIceConnectionState state) {
      if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _cleanup();
      }
    };
  }

  /// Captures local audio and optionally video from the device.
  ///
  /// For voice-only calls, only audio is captured to save bandwidth and
  /// battery. For video calls, the front-facing camera is used with
  /// standard resolution constraints.
  Future<void> _captureLocalMedia(bool video) async {
    final constraints = <String, dynamic>{
      'audio': true,
      'video': video
          ? {
              // Front camera for self-view in video calls.
              'facingMode': 'user',
              // Reasonable defaults that work across devices without
              // requiring capability negotiation.
              'mandatory': {
                'minWidth': '640',
                'minHeight': '480',
                'minFrameRate': '30',
              },
            }
          : false,
    };

    _localStream = await navigator.mediaDevices.getUserMedia(constraints);
    localRenderer?.srcObject = _localStream;
  }

  /// Initializes video renderers for local and remote streams.
  ///
  /// Renderers must be initialized before assigning srcObject. They
  /// allocate platform-specific video rendering surfaces (SurfaceView
  /// on Android, Metal/OpenGL on iOS, canvas on Web).
  Future<void> _initRenderers() async {
    localRenderer = RTCVideoRenderer();
    remoteRenderer = RTCVideoRenderer();
    await localRenderer!.initialize();
    await remoteRenderer!.initialize();
  }

  /// Handles incoming WebRTC signaling messages from the SignalR hub.
  ///
  /// Signal types:
  ///   - 'offer'         — incoming call invitation with SDP
  ///   - 'answer'        — call acceptance response with SDP
  ///   - 'ice-candidate' — network path candidate for connectivity
  ///   - 'hangup'        — remote peer ended the call
  void _handleSignal(Map<String, dynamic> data) {
    final senderId = data['senderId']?.toString();
    final signalType = data['signalType']?.toString();
    final payload = data['payload']?.toString() ?? '';

    if (senderId == null || signalType == null) return;

    switch (signalType) {
      case 'offer':
        // Incoming call — store the caller info and transition to ringing
        // so the UI can show the incoming call screen. The user must
        // explicitly accept via answerCall().
        _remoteDeviceId = senderId;
        _state = CallState.ringing;
        notifyListeners();

      case 'answer':
        // Our outgoing call was accepted — apply the remote SDP and
        // transition to connecting (waiting for ICE to complete).
        if (_peerConnection != null) {
          _peerConnection!.setRemoteDescription(
            RTCSessionDescription(payload, 'answer'),
          );
          _state = CallState.connecting;
          notifyListeners();
        }

      case 'ice-candidate':
        // Parse the pipe-delimited candidate string and add it to the
        // peer connection. Each candidate is a potential network path.
        if (_peerConnection != null) {
          final parts = payload.split('|');
          if (parts.length >= 3) {
            final candidate = RTCIceCandidate(
              parts[0], // candidate string
              parts[1], // sdpMid
              int.tryParse(parts[2]) ?? 0, // sdpMLineIndex
            );
            _peerConnection!.addCandidate(candidate);
          }
        }

      case 'hangup':
        // Remote peer ended the call — clean up our side.
        _cleanup();
    }
  }

  /// Releases all call resources and resets state to idle.
  ///
  /// Called on hangup (local or remote), ICE failure, or disposal.
  /// Order matters: stop tracks before disposing streams, dispose streams
  /// before closing the connection, update state last.
  Future<void> _cleanup() async {
    // Stop all media tracks to release camera/microphone hardware.
    if (_localStream != null) {
      for (final track in _localStream!.getTracks()) {
        await track.stop();
      }
      await _localStream!.dispose();
      _localStream = null;
    }

    if (_remoteStream != null) {
      await _remoteStream!.dispose();
      _remoteStream = null;
    }

    // Dispose renderers to free platform video surfaces.
    if (localRenderer != null) {
      localRenderer!.srcObject = null;
      await localRenderer!.dispose();
      localRenderer = null;
    }
    if (remoteRenderer != null) {
      remoteRenderer!.srcObject = null;
      await remoteRenderer!.dispose();
      remoteRenderer = null;
    }

    // Close the peer connection last — it may still be sending
    // ICE candidates or DTLS teardown messages.
    await _peerConnection?.close();
    _peerConnection = null;

    _remoteDeviceId = null;
    _isMuted = false;
    _state = CallState.ended;
    notifyListeners();

    // Brief delay then reset to idle so the UI can show "call ended"
    // before returning to the ready state.
    Future.delayed(const Duration(seconds: 1), () {
      if (_state == CallState.ended) {
        _state = CallState.idle;
        notifyListeners();
      }
    });
  }

  @override
  void dispose() {
    _signalSubscription?.cancel();
    // Fire-and-forget cleanup — dispose can't be async but we still
    // need to release native resources.
    _cleanup();
    super.dispose();
  }
}
