import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/auth/app_lock.dart';
import '../core/network/webrtc_manager.dart';
import '../l10n/l10n.dart';
import 'router.dart';

/// Why unlocking failed. Kept as a code (not text) so the message follows the
/// current locale and is built where a BuildContext exists.
enum _LockError { storageUnavailable, rejected, unavailable }

/// Keeps call invitations and the local privacy lock active across routes.
class SessionOverlay extends StatefulWidget {
  const SessionOverlay({super.key, required this.child, this.openCall});
  final Widget child;

  /// Opens the call screen for a remote device id. Defaults to pushing
  /// `/call/<id>` on the app router; a test seam, because the global router
  /// cannot be built in a widget test.
  final void Function(String remoteDeviceId)? openCall;
  @override
  State<SessionOverlay> createState() => _SessionOverlayState();
}

class _SessionOverlayState extends State<SessionOverlay>
    with WidgetsBindingObserver {
  final _pin = TextEditingController();
  bool _checking = true;
  bool _locked = false;
  bool _callOpen = false;

  /// Whether the app (widget.child) has been built once; from then on it
  /// stays mounted under the lock screen.
  bool _appBuilt = false;

  /// Whether the biometric prompt was already offered automatically for the
  /// current lock screen. Reset when the app unlocks or goes to the
  /// background, so every return to a locked app asks once, but a cancelled
  /// prompt does not come back on its own (the button stays for that).
  bool _autoPrompted = false;

  /// A system authentication dialog is open. On Android the device
  /// credential fallback is its own activity, so the app reports `paused`
  /// while it is shown: that must not count as leaving the app.
  bool _authInProgress = false;
  _LockError? _error;
  late WebRTCManager _calls;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _calls = context.read<WebRTCManager>()..addListener(_callChanged);
    _checkLock();
  }

  Future<void> _checkLock() async {
    try {
      final enabled = await context.read<AppLock>().isEnabled();
      if (mounted) {
        setState(() {
          _checking = false;
          _locked = enabled;
        });
      }
      if (!enabled) _callChanged();
      if (enabled) _maybeAutoBiometric();
    } catch (_) {
      if (mounted) {
        setState(() {
          _checking = false;
          _locked = true;
          _error = _LockError.storageUnavailable;
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      if (_authInProgress) return;
      _autoPrompted = false;
      _checkLock();
    } else if (state == AppLifecycleState.resumed) {
      _maybeAutoBiometric();
    }
  }

  /// Opens the biometric prompt by itself when the lock screen shows and the
  /// user turned biometrics on, like other apps do: no extra tap on "Use
  /// biometrics". Only while the app is in the foreground (a prompt cannot
  /// show from the background) and once per lock screen.
  void _maybeAutoBiometric() {
    if (!_locked || _autoPrompted || _authInProgress || !mounted) return;
    final state = WidgetsBinding.instance.lifecycleState;
    if (state != null && state != AppLifecycleState.resumed) return;
    _autoPrompted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !_locked) return;
      final lock = context.read<AppLock>();
      try {
        if (!await lock.isBiometricEnabled() ||
            !await lock.isBiometricAvailable()) {
          return;
        }
      } catch (_) {
        return;
      }
      if (mounted && _locked) await _unlock(biometric: true, automatic: true);
    });
  }

  void _callChanged() {
    // The flag is cleared by the CALL ending, not by the pushed route
    // completing: the call screen closes with `context.go('/chats')`, and
    // go_router (17.x) never completes a push() future whose page was removed
    // by go(). Waiting for that future left the flag set for good after the
    // first call, so the next call — incoming or outgoing — never opened the
    // call screen, the callee could not accept and the caller ran into the
    // 45 s timeout ("the second call cannot be established").
    if (_calls.state == CallState.ended || _calls.state == CallState.idle) {
      _callOpen = false;
    }
    if (!mounted || _locked || _checking || _callOpen) return;
    if (_calls.state != CallState.ringing &&
        _calls.state != CallState.connecting) {
      return;
    }
    _callOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final remote = _calls.remoteDeviceId;
      if (!mounted || _locked || remote == null) {
        _callOpen = false;
        return;
      }
      // A call screen left open on "Call ended" already shows the manager's
      // state, so it displays the new call by itself — do not stack a second one.
      if (widget.openCall == null &&
          router.routerDelegate.currentConfiguration.uri.path.startsWith('/call/')) {
        return;
      }
      (widget.openCall ?? (id) => unawaited(router.push('/call/$id')))(remote);
    });
  }

  /// [automatic]: the prompt opened by itself; a cancel there is not an
  /// error worth a red message, the PIN field and the button are right there.
  Future<void> _unlock({bool biometric = false, bool automatic = false}) async {
    if (biometric && _authInProgress) return;
    try {
      final lock = context.read<AppLock>();
      // Read before the first await: the OS prompt shows this reason.
      final reason = context.l10n.lockUnlockTitle;
      if (biometric) _authInProgress = true;
      final bool accepted;
      try {
        accepted = biometric
            ? await lock.isBiometricEnabled() &&
                  await lock.authenticateWithBiometrics(reason: reason)
            : await lock.verifyPin(_pin.text);
      } finally {
        if (biometric) _authInProgress = false;
      }
      if (!mounted) return;
      if (accepted) {
        setState(() {
          _locked = false;
          _autoPrompted = false;
          _error = null;
          _pin.clear();
        });
        _callChanged();
      } else if (!automatic) {
        setState(() => _error = _LockError.rejected);
      }
    } catch (_) {
      if (mounted && !automatic) {
        setState(() => _error = _LockError.unavailable);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final covered = _checking || _locked;
    if (!covered) _appBuilt = true;
    // Until the first unlock nothing of the app is built (as before): a cold
    // start with the lock on must not run any screen behind it.
    if (!_appBuilt) return _lockScreen(context);
    // Once built, the app stays MOUNTED under the lock: replacing it with the
    // lock screen disposed the whole navigator, so an open chat lost the text
    // being typed every time the app went to the background with the lock
    // on. While covered it is not painted, not hit-testable, not in the
    // semantics tree, its animations are paused, and nothing in it can hold
    // focus (a focused composer would otherwise raise the keyboard over the
    // lock screen).
    return Stack(
      fit: StackFit.expand,
      children: [
        ExcludeFocus(
          excluding: covered,
          child: TickerMode(
            enabled: !covered,
            child: ExcludeSemantics(
              excluding: covered,
              child: IgnorePointer(
                ignoring: covered,
                child: Offstage(offstage: covered, child: widget.child),
              ),
            ),
          ),
        ),
        if (covered) _lockScreen(context),
      ],
    );
  }

  Widget _lockScreen(BuildContext context) {
    final l10n = context.l10n;
    return Material(
      child: SafeArea(
        child: Center(
          child: SizedBox(
            width: 320,
            child: _checking
                ? const Center(child: CircularProgressIndicator())
                : Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.lock_outline, size: 48),
                        const SizedBox(height: 16),
                        Text(l10n.lockUnlockTitle),
                        TextField(
                          controller: _pin,
                          obscureText: true,
                          keyboardType: TextInputType.number,
                          maxLength: 6,
                          decoration: InputDecoration(
                            labelText: l10n.lockPinLabel,
                            errorText: switch (_error) {
                              null => null,
                              _LockError.storageUnavailable =>
                                l10n.lockErrorStorageUnavailable,
                              _LockError.rejected => l10n.lockErrorRejected,
                              _LockError.unavailable =>
                                l10n.lockErrorUnavailable,
                            },
                          ),
                          onSubmitted: (_) => _unlock(),
                        ),
                        FilledButton(
                          onPressed: _unlock,
                          child: Text(l10n.lockUnlockButton),
                        ),
                        TextButton(
                          onPressed: () => _unlock(biometric: true),
                          child: Text(l10n.lockUseBiometrics),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _calls.removeListener(_callChanged);
    _pin.dispose();
    super.dispose();
  }
}
