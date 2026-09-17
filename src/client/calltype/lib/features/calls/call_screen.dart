import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:go_router/go_router.dart';
import '../../core/network/webrtc_manager.dart';

class CallScreen extends StatelessWidget {
  const CallScreen({super.key, required this.webrtcManager});
  final WebRTCManager webrtcManager;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: webrtcManager, builder: (context, _) {
      final manager = webrtcManager;
      final ended = manager.state == CallState.ended || manager.state == CallState.idle;
      Future<void> close() async {
        await manager.endCall();
        if (context.mounted) context.go('/chats');
      }
      return PopScope(canPop: ended, onPopInvokedWithResult: (didPop, _) {
        if (!didPop) close();
      }, child: Scaffold(
        appBar: AppBar(title: const Text('Call')),
        body: SafeArea(child: Column(children: [
          Expanded(child: manager.isVideo && manager.remoteRenderer != null
            ? Stack(children: [
                Positioned.fill(child: RTCVideoView(manager.remoteRenderer!)),
                if (manager.localRenderer != null) Positioned(right: 16, top: 16,
                  width: 120, height: 160, child: RTCVideoView(manager.localRenderer!, mirror: true)),
              ])
            : Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.person_outline, size: 80),
                const SizedBox(height: 16),
                Text(manager.remoteDeviceId ?? 'Call ended'),
              ]))),
          Text(manager.error ?? (manager.isIncoming ? 'Incoming ${manager.isVideo ? 'video' : 'voice'} call' : manager.state.name)),
          const SizedBox(height: 20),
          Wrap(spacing: 16, runSpacing: 12, alignment: WrapAlignment.center, children: [
            if (manager.isIncoming) FilledButton.icon(onPressed: manager.acceptCall,
              icon: const Icon(Icons.call), label: const Text('Accept')),
            // Labeled, state-coloured toggles: beta testers did not notice the
            // bare mic icon and there was no way to silence the other side.
            if (!ended && !manager.isIncoming) _CallToggle(
              active: manager.isMuted, onPressed: manager.toggleMute,
              icon: Icons.mic, activeIcon: Icons.mic_off,
              label: 'Mic', activeLabel: 'Mic off'),
            if (!ended && !manager.isIncoming) _CallToggle(
              active: manager.isSpeakerMuted, onPressed: manager.toggleSpeaker,
              icon: Icons.volume_up, activeIcon: Icons.volume_off,
              label: 'Sound', activeLabel: 'Sound off'),
            FilledButton.icon(onPressed: close, icon: const Icon(Icons.call_end),
              label: Text(ended ? 'Close' : manager.isIncoming ? 'Decline' : 'End call')),
            if (manager.isVideo && !manager.isIncoming && !ended) _CallToggle(
              active: manager.isCameraOff, onPressed: manager.toggleCamera,
              icon: Icons.videocam, activeIcon: Icons.videocam_off,
              label: 'Camera', activeLabel: 'Camera off'),
            // Diagnostics only: shows which ICE candidate type carries the
            // media (expect "relay" when the force-relay switch is on). The
            // summary is redacted — no IPs or SDP — so it is safe to screenshot
            // into acceptance evidence.
            if (manager.forceIceRelay && !ended && !manager.isIncoming)
              TextButton.icon(
                icon: const Icon(Icons.alt_route_rounded),
                label: const Text('Route'),
                onPressed: () async {
                  final summary = await manager.getSelectedCandidateSummary();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
                    summary == null
                        ? 'No selected candidate yet'
                        : 'Route: ${summary['type']} / ${summary['protocol']}')));
                }),
          ]),
          const SizedBox(height: 32),
        ])),
      ));
    });
}

/// Round in-call toggle with a caption. "Active" means the restriction is ON
/// (mic/sound/camera off) and is drawn in the error colour so a muted state
/// is obvious at a glance.
class _CallToggle extends StatelessWidget {
  const _CallToggle({
    required this.active,
    required this.onPressed,
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.activeLabel,
  });
  final bool active;
  final VoidCallback onPressed;
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final String activeLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      IconButton.filledTonal(
        onPressed: onPressed,
        isSelected: active,
        iconSize: 28,
        tooltip: active ? activeLabel : label,
        style: IconButton.styleFrom(
          backgroundColor: active ? scheme.errorContainer : null,
          foregroundColor: active ? scheme.onErrorContainer : null,
          minimumSize: const Size(56, 56),
        ),
        icon: Icon(active ? activeIcon : icon),
      ),
      const SizedBox(height: 4),
      Text(active ? activeLabel : label, style: Theme.of(context).textTheme.labelSmall),
    ]);
  }
}
