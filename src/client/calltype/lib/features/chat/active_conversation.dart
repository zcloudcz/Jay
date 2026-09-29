import 'package:flutter/widgets.dart';

/// Which conversation the user is looking at right now (null = none).
///
/// Contract M §4.5 (docs/superpowers/plans/2026-09-29-gap-contracts.md §5),
/// created in wave 0 so streams can code against it in parallel:
/// - N reads it to skip the local notification for the chat that is already
///   open and visible (WhatsApp-style) — hence the foreground check, because
///   an "open" chat in a backgrounded app is not visible and must still notify.
/// - M04 reads it to send `receipt kind:read` only for messages the user can
///   actually see.
/// The chat screen (stream M) sets [value] on open and clears it on close.
/// It is provided app-wide from `main.dart`.
class ActiveConversation extends ValueNotifier<String?> {
  ActiveConversation({AppLifecycleState? Function()? lifecycleState})
    : _lifecycleState =
          lifecycleState ?? (() => WidgetsBinding.instance.lifecycleState),
      super(null);

  // Injectable so tests (and the headless notification isolate, which has no
  // meaningful lifecycle) do not depend on the global binding.
  final AppLifecycleState? Function() _lifecycleState;

  /// True while the app window is visible and focused.
  ///
  /// A null lifecycle state means the binding has not reported one yet
  /// (early start-up); that only happens while the first frame is being
  /// built in the foreground, so it counts as foreground.
  bool get appInForeground {
    final state = _lifecycleState();
    return state == null || state == AppLifecycleState.resumed;
  }
}
