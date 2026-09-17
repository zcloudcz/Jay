import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/auth/app_lock.dart';
import '../../l10n/l10n.dart';

/// Settings screen for configuring PIN lock and biometric authentication.
///
/// UI layout:
///   - Switch to enable/disable PIN lock (shows set/confirm PIN dialog)
///   - Switch for biometrics (visible only when PIN is enabled AND hardware
///     supports it)
///
/// The screen loads the current lock state asynchronously on init because
/// secure storage reads are async. While loading, switches are disabled to
/// prevent race conditions.
class AppLockSettingsScreen extends StatefulWidget {
  const AppLockSettingsScreen({super.key});

  @override
  State<AppLockSettingsScreen> createState() => _AppLockSettingsScreenState();
}

class _AppLockSettingsScreenState extends State<AppLockSettingsScreen> {
  bool _loading = true;
  bool _pinEnabled = false;
  bool _biometricAvailable = false;
  bool _biometricEnabled = false;

  @override
  void initState() {
    super.initState();
    // Defer the async load to after the first frame so context.read is safe.
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadState());
  }

  /// Reads current lock configuration from secure storage and platform APIs.
  Future<void> _loadState() async {
    final appLock = context.read<AppLock>();

    final pinEnabled = await appLock.isEnabled();
    final bioAvailable = await appLock.isBiometricAvailable();
    final bioEnabled = await appLock.isBiometricEnabled();

    if (mounted) {
      setState(() {
        _pinEnabled = pinEnabled;
        _biometricAvailable = bioAvailable;
        _biometricEnabled = bioEnabled;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = context.l10n;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.appLockTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                // -- Explanation header -----------------------------------------
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    l10n.appLockExplanation,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),

                // -- PIN lock toggle --------------------------------------------
                SwitchListTile(
                  title: Text(l10n.appLockPin),
                  subtitle: Text(
                    _pinEnabled
                        ? l10n.appLockPinDisableHint
                        : l10n.appLockPinEnableHint,
                  ),
                  secondary: Icon(
                    Icons.lock_rounded,
                    color: colorScheme.primary,
                  ),
                  value: _pinEnabled,
                  onChanged: (enabled) {
                    if (enabled) {
                      _showSetPinDialog();
                    } else {
                      _disablePin();
                    }
                  },
                ),

                // -- Biometric toggle -------------------------------------------
                // Only shown when PIN is active AND the device has biometric
                // hardware. No point offering biometrics without a PIN fallback.
                if (_pinEnabled && _biometricAvailable)
                  SwitchListTile(
                    title: Text(l10n.appLockBiometric),
                    subtitle: Text(l10n.appLockBiometricSubtitle),
                    secondary: Icon(
                      Icons.fingerprint_rounded,
                      color: colorScheme.primary,
                    ),
                    value: _biometricEnabled,
                    onChanged: (enabled) => _toggleBiometric(enabled),
                  ),
              ],
            ),
    );
  }

  /// Shows a dialog to set a new 4-6 digit PIN.
  ///
  /// The dialog collects the PIN in an obscured text field and validates
  /// the length before accepting. On success, the PIN is hashed and stored.
  Future<void> _showSetPinDialog() async {
    final pinController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final l10n = context.l10n;

    final pin = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(l10n.appLockSetPinTitle),
          content: Form(
            key: formKey,
            child: TextFormField(
              controller: pinController,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              autofocus: true,
              decoration: InputDecoration(
                labelText: l10n.appLockEnterPinLabel,
                border: const OutlineInputBorder(),
              ),
              validator: (value) {
                if (value == null || value.length < 4) {
                  return l10n.appLockPinTooShort;
                }
                if (!RegExp(r'^\d+$').hasMatch(value)) {
                  return l10n.appLockPinDigitsOnly;
                }
                return null;
              },
              onFieldSubmitted: (value) {
                if (formKey.currentState!.validate()) {
                  Navigator.of(dialogContext).pop(value);
                }
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.commonCancel),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState!.validate()) {
                  Navigator.of(dialogContext).pop(pinController.text);
                }
              },
              child: Text(l10n.appLockSet),
            ),
          ],
        );
      },
    );

    pinController.dispose();

    if (pin != null && pin.isNotEmpty && mounted) {
      final appLock = context.read<AppLock>();
      await appLock.setPin(pin);
      setState(() => _pinEnabled = true);
    }
  }

  /// Disables PIN lock after verifying the current PIN.
  ///
  /// Asks the user to enter their current PIN to prevent unauthorized
  /// disabling. If verification succeeds, the PIN hash is removed.
  Future<void> _disablePin() async {
    final pinController = TextEditingController();
    final l10n = context.l10n;

    final enteredPin = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(l10n.appLockCurrentPinTitle),
          content: TextField(
            controller: pinController,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            autofocus: true,
            decoration: InputDecoration(
              labelText: l10n.appLockCurrentPinLabel,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (value) {
              Navigator.of(dialogContext).pop(value);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.commonCancel),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(pinController.text);
              },
              child: Text(l10n.appLockVerify),
            ),
          ],
        );
      },
    );

    pinController.dispose();

    if (enteredPin == null || !mounted) return;

    final appLock = context.read<AppLock>();
    final verified = await appLock.verifyPin(enteredPin);

    if (verified) {
      await appLock.removePin();
      if (mounted) {
        setState(() {
          _pinEnabled = false;
          _biometricEnabled = false;
        });
      }
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.appLockIncorrectPin)),
      );
    }
  }

  /// Toggles biometric authentication on or off.
  Future<void> _toggleBiometric(bool enabled) async {
    final appLock = context.read<AppLock>();
    await appLock.setBiometricEnabled(enabled);
    if (mounted) {
      setState(() => _biometricEnabled = enabled);
    }
  }
}
