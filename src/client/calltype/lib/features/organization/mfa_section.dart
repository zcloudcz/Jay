import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:calltype_core/network/api_client.dart';
import '../../l10n/l10n.dart';
import 'mfa_controller.dart';
import 'mfa_flow.dart';

/// The MFA (TOTP) card: status, enable/disable, regenerate backup codes.
/// Embedded by the Organization screen (org admins only, its `isAdmin`
/// branch) and by the Account screen (every registered account, needed for
/// the moderation web). The embedding screen decides who sees it.
class MfaSection extends StatefulWidget {
  const MfaSection({super.key, required this.accountId});

  final String accountId;

  @override
  State<MfaSection> createState() => _MfaSectionState();
}

class _MfaSectionState extends State<MfaSection> {
  late final MfaController _mfa;

  @override
  void initState() {
    super.initState();
    _mfa = MfaController(
      apiClient: context.read<ApiClient>(),
      accountId: widget.accountId,
    )..loadStatus();
  }

  @override
  void dispose() {
    _mfa.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _mfa,
      builder: (context, _) {
        final l10n = context.l10n;
        final status = _mfa.status;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.mfaSectionTitle, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                if (status == null)
                  const Center(child: CircularProgressIndicator())
                else if (!status.enabled) ...[
                  Text(l10n.mfaStatusDisabled),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: () async {
                      final ok = await runMfaEnrollmentFlow(context, _mfa);
                      if (ok) await _mfa.loadStatus();
                    },
                    child: Text(l10n.mfaEnableButton),
                  ),
                ] else ...[
                  Text(l10n.mfaStatusEnabled),
                  Text(l10n.mfaBackupCodesRemaining(status.backupCodesRemaining)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: () async {
                          final codes = await _showRegenerateConfirm(context) ?? false;
                          if (!codes) return;
                          final newCodes = await _mfa.regenerateBackupCodes();
                          if (newCodes != null && context.mounted) {
                            await showBackupCodesOnce(context, newCodes);
                          }
                        },
                        child: Text(l10n.mfaRegenerateButton),
                      ),
                      OutlinedButton(
                        onPressed: () async {
                          final code = await _showDisableCodePrompt(context);
                          if (code != null && code.isNotEmpty) {
                            await _mfa.disable(code);
                          }
                        },
                        child: Text(l10n.mfaDisableButton),
                      ),
                    ],
                  ),
                ],
                if (_mfa.errorCode != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      mfaErrorMessage(context, _mfa.errorCode),
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<bool?> _showRegenerateConfirm(BuildContext context) {
    final l10n = context.l10n;
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.mfaRegenerateButton),
        content: Text(l10n.mfaBackupCodesWarning),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.mfaCancelButton),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.mfaRegenerateButton),
          ),
        ],
      ),
    );
  }

  Future<String?> _showDisableCodePrompt(BuildContext context) {
    final l10n = context.l10n;
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.mfaDisableButton),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: l10n.mfaVerifyCodeLabel),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.mfaCancelButton),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: Text(l10n.mfaDisableButton),
          ),
        ],
      ),
    );
  }
}
