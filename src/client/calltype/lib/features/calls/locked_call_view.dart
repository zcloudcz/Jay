import 'package:flutter/widgets.dart';

import '../../core/network/webrtc_manager.dart';

/// The call screen shown on top of the app lock (contracts K10, calls C08).
///
/// A call must be answerable and controllable while the app lock is up,
/// without exposing a single chat. `SessionOverlay` (owned by stream S; C may
/// only touch `_callChanged` and the call branch of `build`) renders this
/// widget instead of the router while a call is active and the app is locked.
///
/// Wave-0 stub: renders nothing and is not referenced yet. Stream C (C08)
/// replaces the body with a `Navigator` hosting `CallScreen(lockedMode: true)`
/// — a Navigator because the lock UI replaces the router, so without one
/// there is no `Overlay` above the screen and `IconButton` tooltips crash.
class LockedCallView extends StatelessWidget {
  const LockedCallView({super.key, required this.webrtcManager, this.onClosed});

  final WebRTCManager webrtcManager;

  /// Called after the call ends, so the overlay can return to the lock UI.
  final VoidCallback? onClosed;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
