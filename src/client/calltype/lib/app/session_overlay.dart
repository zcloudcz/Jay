import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/auth/app_lock.dart';
import '../core/network/webrtc_manager.dart';
import 'router.dart';

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
  String? _error;
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
          _error = 'Secure storage is unavailable. Try unlocking again.';
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
      final accepted = biometric
          ? await lock.isBiometricEnabled() &&
                await lock.authenticateWithBiometrics()
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
        setState(() => _error = 'Could not unlock. Try again.');
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Unlock is unavailable. Try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_checking && !_locked) return widget.child;
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
                        const Text('Unlock Jay'),
                        TextField(
                          controller: _pin,
                          obscureText: true,
                          keyboardType: TextInputType.number,
                          maxLength: 6,
                          decoration: InputDecoration(
                            labelText: 'PIN',
                            errorText: _error,
                          ),
                          onSubmitted: (_) => _unlock(),
                        ),
                        FilledButton(
                          onPressed: _unlock,
                          child: const Text('Unlock'),
                        ),
                        TextButton(
                          onPressed: () => _unlock(biometric: true),
                          child: const Text('Use biometrics'),
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
