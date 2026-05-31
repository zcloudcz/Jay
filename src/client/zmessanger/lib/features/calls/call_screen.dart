import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../core/network/webrtc_manager.dart';

/// Full-screen call interface for voice and video calls.
///
/// Layout adapts based on call state and media type:
///   - **Video call, connected:** Remote video fills the screen with a small
///     local video overlay in the top-right corner (picture-in-picture style).
///   - **Voice call or connecting:** Dark background with centered caller info
///     (avatar icon, device ID, state text).
///   - **Controls:** Bottom action bar with mute, end call, and camera toggle.
///
/// Uses [ListenableBuilder] to rebuild reactively when [WebRTCManager]
/// state changes (call connected, mute toggled, etc.) without requiring
/// the parent to manage rebuilds.
class CallScreen extends StatelessWidget {
  const CallScreen({
    super.key,
    required this.webrtcManager,
  });

  /// The WebRTC manager controlling this call's lifecycle.
  /// Passed in rather than looked up via Provider because the call screen
  /// needs the exact instance that owns the active peer connection.
  final WebRTCManager webrtcManager;

  @override
  Widget build(BuildContext context) {
    // PopScope prevents accidental back-navigation during a call.
    // The user must explicitly press the end-call button.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          webrtcManager.endCall();
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        // Black background matches standard call UI conventions and
        // provides good contrast for video content and white text.
        backgroundColor: Colors.black,
        body: SafeArea(
          child: ListenableBuilder(
            listenable: webrtcManager,
            builder: (context, _) {
              return Stack(
                children: [
                  // -- Remote video (full screen) ----------------------------
                  // Only show when connected and video is active. Audio-only
                  // calls show the caller info card instead.
                  if (_showRemoteVideo)
                    Positioned.fill(
                      child: RTCVideoView(
                        webrtcManager.remoteRenderer!,
                        objectFit:
                            RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                      ),
                    ),

                  // -- Caller info (centered) --------------------------------
                  // Shown during ringing/connecting states and for voice calls.
                  // Overlays the video when connected so the user always sees
                  // who they're talking to.
                  if (!_showRemoteVideo) _buildCallerInfo(context),

                  // -- Local video preview (small overlay) -------------------
                  // Picture-in-picture self-view in the top-right corner.
                  // Mirrored so it matches what the user sees in a mirror
                  // (front camera is naturally mirrored).
                  if (_showLocalVideo)
                    Positioned(
                      top: 16,
                      right: 16,
                      width: 120,
                      height: 160,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: RTCVideoView(
                          webrtcManager.localRenderer!,
                          mirror: true,
                          objectFit:
                              RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                        ),
                      ),
                    ),

                  // -- Bottom controls ---------------------------------------
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 32,
                    child: _buildControls(context),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Whether to show the remote video view.
  /// Only when connected, video is active, and the renderer is ready.
  bool get _showRemoteVideo =>
      webrtcManager.state == CallState.connected &&
      webrtcManager.isVideo &&
      webrtcManager.remoteRenderer != null;

  /// Whether to show the local video preview overlay.
  bool get _showLocalVideo =>
      webrtcManager.isVideo && webrtcManager.localRenderer != null;

  /// Builds the centered caller info card shown during non-video states.
  ///
  /// Displays a large person icon, the remote device ID (or "Unknown"),
  /// and a text label for the current call state. This is the primary
  /// visual feedback during voice calls and while connecting.
  Widget _buildCallerInfo(BuildContext context) {
    final stateText = switch (webrtcManager.state) {
      CallState.ringing => 'Ringing...',
      CallState.connecting => 'Connecting...',
      CallState.connected => 'Connected',
      CallState.ended => 'Call ended',
      CallState.idle => '',
    };

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Large avatar placeholder — will be replaced with actual
          // contact avatar once the contacts system stores profile images.
          const CircleAvatar(
            radius: 48,
            backgroundColor: Colors.white24,
            child: Icon(Icons.person, size: 48, color: Colors.white),
          ),
          const SizedBox(height: 24),

          // Device ID of the remote participant. Truncated with ellipsis
          // for very long IDs, though UUIDs fit comfortably.
          Text(
            webrtcManager.remoteDeviceId ?? 'Unknown',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w500,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),

          Text(
            stateText,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }

  /// Builds the bottom control bar with call action buttons.
  ///
  /// Layout: [Mute] — [End Call] — [Camera Toggle]
  /// The end call button is always red and prominent. Mute and camera
  /// buttons toggle their appearance based on current state.
  Widget _buildControls(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        // Mute toggle — icon changes to indicate current state.
        _CallButton(
          icon: webrtcManager.isMuted ? Icons.mic_off : Icons.mic,
          label: webrtcManager.isMuted ? 'Unmute' : 'Mute',
          backgroundColor: webrtcManager.isMuted ? Colors.red : Colors.white24,
          onPressed: webrtcManager.toggleMute,
        ),

        // End call — always available, always red. This is the primary
        // action during a call so it's larger and more prominent.
        _CallButton(
          icon: Icons.call_end,
          label: 'End',
          backgroundColor: Colors.red,
          size: 64,
          onPressed: () {
            webrtcManager.endCall();
            Navigator.of(context).pop();
          },
        ),

        // Camera toggle — only functional during video calls.
        // Still visible during voice calls but disabled (greyed out)
        // to maintain consistent layout.
        if (webrtcManager.isVideo)
          _CallButton(
            icon: Icons.videocam,
            label: 'Camera',
            backgroundColor: Colors.white24,
            onPressed: webrtcManager.toggleCamera,
          )
        else
          // Invisible spacer to keep the end-call button centered
          // when camera toggle is not shown.
          const SizedBox(width: 64),
      ],
    );
  }
}

/// Circular action button used in the call controls bar.
///
/// Encapsulates the common pattern of icon + label + colored background
/// used by all call control buttons. The [size] parameter allows the
/// end-call button to be visually larger than secondary controls.
class _CallButton extends StatelessWidget {
  const _CallButton({
    required this.icon,
    required this.label,
    required this.backgroundColor,
    required this.onPressed,
    this.size = 52,
  });

  final IconData icon;
  final String label;
  final Color backgroundColor;
  final VoidCallback onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: size,
          height: size,
          child: FloatingActionButton(
            heroTag: label,
            backgroundColor: backgroundColor,
            onPressed: onPressed,
            child: Icon(icon, color: Colors.white),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ],
    );
  }
}
