import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:go_router/go_router.dart';
import '../../core/network/webrtc_manager.dart';
import '../../l10n/l10n.dart';

class CallScreen extends StatelessWidget {
  const CallScreen({super.key, required this.webrtcManager});
  final WebRTCManager webrtcManager;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: webrtcManager, builder: (context, _) {
      final manager = webrtcManager;
      final l10n = context.l10n;
      // Error first, then the incoming prompt, then the plain call state.
      final status = switch (manager.error) {
        CallError.connectionFailed => l10n.callErrorConnectionFailed,
        CallError.noAnswer => l10n.callErrorNoAnswer,
        CallError.cannotStart => l10n.callErrorCannotStart,
        CallError.cannotAccept => l10n.callErrorCannotAccept,
        CallError.userOffline => l10n.callErrorUserOffline,
        // Reuses the business-message wording (KB2/W2-F) — same fail-closed
        // rule, same "try again" phrasing, no separate key needed.
        CallError.auditorUnavailable => l10n.hubErrorAuditorUnavailable,
        CallError.notABusinessMember => l10n.callErrorCannotStart,
        CallError.declined => l10n.callErrorDeclined,
        null when manager.isIncoming =>
          manager.isVideo ? l10n.callIncomingVideo : l10n.callIncomingVoice,
        null => switch (manager.state) {
          // R5: the callee's phone rings via CallKit / full-screen
          // notification although its app is closed.
          CallState.ringing => manager.isRemoteRinging
              ? l10n.callStateRinging : l10n.callStateCalling,
          CallState.connecting => l10n.callStateConnecting,
          CallState.connected => l10n.callStateConnected,
          CallState.idle || CallState.ended => l10n.callEnded,
        },
      };
      final ended = manager.state == CallState.ended || manager.state == CallState.idle;
      Future<void> close() async {
        await manager.endCall();
        if (context.mounted) context.go('/chats');
      }
      return PopScope(canPop: ended, onPopInvokedWithResult: (didPop, _) {
        if (!didPop) close();
      }, child: Scaffold(
        appBar: AppBar(title: Text(l10n.callTitle)),
        body: SafeArea(child: Column(children: [
          // Owner decision (H1/H2): a business call is metadata-logged, never
          // "recorded" — shown to BOTH sides, before the callee even accepts,
          // so nobody is surprised after the fact.
          if (manager.businessGroupId != null)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.secondaryContainer,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                l10n.callBusinessNotice,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSecondaryContainer,
                  fontSize: 12,
                ),
              ),
            ),
          Expanded(child: manager.isVideo && manager.remoteRenderer != null
            ? Stack(children: [
                Positioned.fill(child: RTCVideoView(manager.remoteRenderer!)),
                if (manager.localRenderer != null) Positioned(right: 16, top: 16,
                  width: 120, height: 160, child: RTCVideoView(manager.localRenderer!, mirror: true)),
              ])
            : Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.person_outline, size: 80),
                const SizedBox(height: 16),
                Text(manager.remoteDeviceId ?? l10n.callEnded),
              ]))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(status, textAlign: TextAlign.center),
          ),
          const SizedBox(height: 20),
          Wrap(spacing: 16, runSpacing: 12, alignment: WrapAlignment.center, children: [
            if (manager.isIncoming) FilledButton.icon(onPressed: manager.acceptCall,
              icon: const Icon(Icons.call), label: Text(l10n.callAccept)),
            // Labeled, state-coloured toggles: beta testers did not notice the
            // bare mic icon and there was no way to silence the other side.
            if (!ended && !manager.isIncoming) _CallToggle(
              active: manager.isMuted, onPressed: manager.toggleMute,
              icon: Icons.mic, activeIcon: Icons.mic_off,
              label: l10n.callMic, activeLabel: l10n.callMicOff),
            if (!ended && !manager.isIncoming) _CallToggle(
              active: manager.isSpeakerMuted, onPressed: manager.toggleSpeaker,
              icon: Icons.volume_up, activeIcon: Icons.volume_off,
              label: l10n.callSound, activeLabel: l10n.callSoundOff),
            FilledButton.icon(onPressed: close, icon: const Icon(Icons.call_end),
              label: Text(ended ? l10n.callClose : manager.isIncoming ? l10n.callDecline : l10n.callEnd)),
            if (manager.isVideo && !manager.isIncoming && !ended) _CallToggle(
              active: manager.isCameraOff, onPressed: manager.toggleCamera,
              icon: Icons.videocam, activeIcon: Icons.videocam_off,
              label: l10n.callCamera, activeLabel: l10n.callCameraOff),
            // Diagnostics only: shows which ICE candidate type carries the
            // media (expect "relay" when the force-relay switch is on). The
            // summary is redacted — no IPs or SDP — so it is safe to screenshot
            // into acceptance evidence.
            if (manager.forceIceRelay && !ended && !manager.isIncoming)
              TextButton.icon(
                icon: const Icon(Icons.alt_route_rounded),
                label: Text(l10n.callRoute),
                onPressed: () async {
                  final summary = await manager.getSelectedCandidateSummary();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
                    summary == null
                        ? l10n.callRouteNone
                        : l10n.callRouteSummary(
                            '${summary['type']}', '${summary['protocol']}'))));
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
