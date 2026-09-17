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
  const SessionOverlay({super.key, required this.child});
  final Widget child;
  @override
  State<SessionOverlay> createState() => _SessionOverlayState();
}

class _SessionOverlayState extends State<SessionOverlay>
    with WidgetsBindingObserver {
  final _pin = TextEditingController();
  bool _checking = true;
  bool _locked = false;
  bool _callOpen = false;
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
      _checkLock();
    }
  }

  void _callChanged() {
    if (!mounted || _locked || _checking || _callOpen) return;
    if (_calls.state != CallState.ringing &&
        _calls.state != CallState.connecting) {
      return;
    }
    _callOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _locked) {
        _callOpen = false;
        return;
      }
      await router.push('/call/${_calls.remoteDeviceId}');
      _callOpen = false;
    });
  }

  Future<void> _unlock({bool biometric = false}) async {
    try {
      final lock = context.read<AppLock>();
      // Read before the first await: the OS prompt shows this reason.
      final reason = context.l10n.lockUnlockTitle;
      final accepted = biometric
          ? await lock.isBiometricEnabled() &&
                await lock.authenticateWithBiometrics(reason: reason)
          : await lock.verifyPin(_pin.text);
      if (!mounted) return;
      if (accepted) {
        setState(() {
          _locked = false;
          _error = null;
          _pin.clear();
        });
        _callChanged();
      } else {
        setState(() => _error = _LockError.rejected);
      }
    } catch (_) {
      if (mounted) setState(() => _error = _LockError.unavailable);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_checking && !_locked) return widget.child;
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
