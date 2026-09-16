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
            if (!ended && !manager.isIncoming) IconButton(onPressed: manager.toggleMute,
              icon: Icon(manager.isMuted ? Icons.mic_off : Icons.mic), tooltip: 'Mute microphone'),
            FilledButton.icon(onPressed: close, icon: const Icon(Icons.call_end),
              label: Text(ended ? 'Close' : manager.isIncoming ? 'Decline' : 'End call')),
            if (manager.isVideo && !manager.isIncoming && !ended) IconButton(onPressed: manager.toggleCamera,
              icon: const Icon(Icons.videocam), tooltip: 'Toggle camera'),
          ]),
          const SizedBox(height: 32),
        ])),
      ));
    });
}
