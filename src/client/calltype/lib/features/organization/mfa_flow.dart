import 'package:calltype_core/network/mfa_api.dart';
import 'package:calltype_core/network/mfa_dtos.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/network/api_client.dart';
import '../../l10n/l10n.dart';
import 'mfa_controller.dart';

/// Runs the full "prove you're still you" flow for a gated organization or
/// emergency admin action, and returns whether the action should be
/// retried — this is exactly the `promptAndVerify` argument [withMfa]
/// (`calltype_core/network/mfa_api.dart`) expects.
///
/// If the account has no MFA enrolled yet, the account is not silently let
/// through — it is walked through enrolment first (owner decision: MFA is
/// mandatory for org admin roles, no grace period), then asked to verify a
/// fresh code so the retried action actually carries a step-up token.
Future<bool> runMfaStepUpFlow(
  BuildContext context,
  ApiClient apiClient,
  String accountId,
) async {
  final mfa = MfaController(apiClient: apiClient, accountId: accountId);
  await mfa.loadStatus();
  if (mfa.status == null) return false;

  if (!mfa.status!.enabled) {
    if (!context.mounted) return false;
    final wantsToEnroll = await _showEnrollExplainer(context);
    if (wantsToEnroll != true) return false;
    if (!context.mounted) return false;
    final enrolled = await runMfaEnrollmentFlow(context, mfa);
    if (!enrolled) return false;
  }

  if (!context.mounted) return false;
  return _showVerifyDialog(context, mfa);
}

Future<bool?> _showEnrollExplainer(BuildContext context) {
  final l10n = context.l10n;
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.mfaRequiredExplainerTitle),
      content: Text(l10n.mfaRequiredExplainerBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.mfaCancelButton),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.mfaEnrollButton),
        ),
      ],
    ),
  );
}

/// Passphrase → QR/secret → 6-digit confirm → backup codes shown once →
/// one more verify (so the caller ends up with a fresh step-up token).
/// Used both from [runMfaStepUpFlow] and directly from the MFA section's
/// "Enable" button.
Future<bool> runMfaEnrollmentFlow(BuildContext context, MfaController mfa) async {
  final passphrase = await _showPassphrasePrompt(context);
  if (passphrase == null || passphrase.isEmpty) return false;

  final enrollment = await mfa.startEnrollment(passphrase);
  if (enrollment == null) return false;

  if (!context.mounted) return false;
  final code = await _showScanAndConfirmDialog(context, enrollment);
  if (code == null || code.isEmpty) return false;

  final backupCodes = await mfa.confirmEnrollment(code);
  if (backupCodes == null) return false;

  if (!context.mounted) return false;
  await _showBackupCodesDialog(context, backupCodes);

  if (!context.mounted) return false;
  return _showVerifyDialog(context, mfa);
}

Future<String?> _showPassphrasePrompt(BuildContext context) {
  final l10n = context.l10n;
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.mfaPassphraseTitle),
      content: TextField(
        controller: controller,
        obscureText: true,
        autofocus: true,
        decoration: InputDecoration(labelText: l10n.mfaPassphraseLabel),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.mfaCancelButton),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text),
          child: Text(l10n.mfaPassphraseSubmit),
        ),
      ],
    ),
  );
}

Future<String?> _showScanAndConfirmDialog(
  BuildContext context,
  MfaEnrollment enrollment,
) {
  final l10n = context.l10n;
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.mfaEnrollScanTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.mfaEnrollScanBody),
            const SizedBox(height: 16),
            Center(child: QrImageView(data: enrollment.otpauthUri, size: 200)),
            const SizedBox(height: 8),
            Text(l10n.mfaEnrollSecretLabel),
            SelectableText(enrollment.secretBase32),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: l10n.mfaEnrollCodeLabel),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.mfaCancelButton),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(controller.text.trim()),
          child: Text(l10n.mfaEnrollConfirmButton),
        ),
      ],
    ),
  );
}

/// Public entry point for showing a set of backup codes exactly once —
/// used both by the enrolment flow and by "regenerate backup codes".
Future<void> showBackupCodesOnce(BuildContext context, List<String> codes) =>
    _showBackupCodesDialog(context, codes);

Future<void> _showBackupCodesDialog(BuildContext context, List<String> codes) {
  final l10n = context.l10n;
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text(l10n.mfaBackupCodesTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.mfaBackupCodesWarning,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            for (final code in codes) SelectableText(code),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.copy_all_outlined),
          label: Text(l10n.mfaBackupCodesCopyAll),
          onPressed: () => Clipboard.setData(ClipboardData(text: codes.join('\n'))),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.mfaBackupCodesDone),
        ),
      ],
    ),
  );
}

Future<bool> _showVerifyDialog(BuildContext context, MfaController mfa) async {
  final l10n = context.l10n;
  final controller = TextEditingController();
  var useBackupCode = false;
  String? lastErrorCode;

  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(l10n.mfaVerifyTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: useBackupCode ? TextInputType.text : TextInputType.number,
              decoration: InputDecoration(
                labelText: useBackupCode
                    ? l10n.mfaVerifyBackupCodeLabel
                    : l10n.mfaVerifyCodeLabel,
              ),
            ),
            TextButton(
              onPressed: () => setState(() => useBackupCode = !useBackupCode),
              child: Text(l10n.mfaVerifyUseBackupCode),
            ),
            if (lastErrorCode != null)
              Text(
                mfaErrorMessage(context, lastErrorCode),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.mfaCancelButton),
          ),
          FilledButton(
            onPressed: () async {
              final input = controller.text.trim();
              final success = useBackupCode
                  ? await mfa.verify(backupCode: input)
                  : await mfa.verify(code: input);
              if (success) {
                if (context.mounted) Navigator.of(context).pop(true);
              } else {
                setState(() => lastErrorCode = mfa.errorCode);
              }
            },
            child: Text(l10n.mfaVerifyButton),
          ),
        ],
      ),
    ),
  );
  return ok ?? false;
}

/// The calm locked state shown instead of a raw error when an admin screen's
/// own data load needed a step-up and the user cancelled the prompt — never
/// a dialog loop, never a raw error banner.
class MfaLockedPlaceholder extends StatelessWidget {
  const MfaLockedPlaceholder({super.key, required this.onUnlock});

  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline, size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text(l10n.mfaLockedTitle, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(l10n.mfaLockedBody, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onUnlock, child: Text(l10n.mfaUnlockButton)),
          ],
        ),
      ),
    );
  }
}

/// Maps [MfaErrorCodes] to a localized, actionable message. Falls back to
/// the generic `{code}` text organization errors already use.
String mfaErrorMessage(BuildContext context, String? code) {
  final l10n = context.l10n;
  switch (code) {
    case MfaErrorCodes.invalidCode:
      return l10n.mfaErrorInvalidCode;
    case MfaErrorCodes.codeReused:
      return l10n.mfaErrorCodeReused;
    case MfaErrorCodes.locked:
      return l10n.mfaErrorLocked;
    case MfaErrorCodes.notConfigured:
      return l10n.mfaErrorNotConfigured;
    case MfaErrorCodes.alreadyEnabled:
      return l10n.mfaErrorAlreadyEnabled;
    default:
      return l10n.orgErrorGeneric(code ?? 'unknown');
  }
}
