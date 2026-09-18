import 'package:calltype_core/network/emergency_dtos.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../l10n/l10n.dart';
import 'emergency_controller.dart';

/// Admin screen for the emergency channel (E07 deliverable 5): issue/revoke
/// kits, run drills, export the readiness proof. Mirrors OrganizationScreen's
/// structure (ListView + inline forms) rather than introducing a new pattern.
class EmergencyScreen extends StatefulWidget {
  const EmergencyScreen({super.key, required this.organizationId});

  final String organizationId;

  @override
  State<EmergencyScreen> createState() => _EmergencyScreenState();
}

class _EmergencyScreenState extends State<EmergencyScreen> {
  final _labelController = TextEditingController();
  final _countController = TextEditingController(text: '5');

  @override
  void dispose() {
    _labelController.dispose();
    _countController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<EmergencyController>();
    final l10n = context.l10n;

    // The just-issued kit is shown exactly once, as a dialog, then cleared
    // from controller state — scheduled after the frame so build() stays pure.
    if (controller.justIssuedKit != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showIssuedKitDialog(context, controller.justIssuedKit!);
        controller.clearJustIssuedKit();
      });
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.emergencyTitle)),
      body: controller.isLoading && controller.kits.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (controller.errorCode != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      l10n.orgErrorGeneric(controller.errorCode!),
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                Text(l10n.emergencyKitsTitle, style: Theme.of(context).textTheme.titleMedium),
                for (final kit in controller.kits)
                  ListTile(
                    leading: Icon(kit.isRevoked ? Icons.block : Icons.vpn_key_outlined),
                    title: Text(kit.label),
                    subtitle: Text(
                      kit.isRevoked
                          ? l10n.emergencyKitRevoked
                          : l10n.emergencyCodesRemaining(kit.codesRemaining, kit.codesTotal),
                    ),
                    trailing: kit.isRevoked
                        ? null
                        : TextButton(
                            onPressed: () => controller.revokeKit(kit.kitId),
                            child: Text(l10n.emergencyRevokeKit),
                          ),
                  ),
                const SizedBox(height: 8),
                TextField(
                  controller: _labelController,
                  decoration: InputDecoration(labelText: l10n.emergencyKitLabelField),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _countController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: l10n.emergencyKitCountField),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  icon: const Icon(Icons.add_moderator_outlined),
                  label: Text(l10n.emergencyIssueKit),
                  onPressed: controller.isLoading
                      ? null
                      : () {
                          final count = int.tryParse(_countController.text.trim()) ?? 0;
                          controller.issueKit(_labelController.text.trim(), count);
                        },
                ),
                const Divider(height: 32),
                Text(l10n.emergencyDrillsTitle, style: Theme.of(context).textTheme.titleMedium),
                for (final drill in controller.drills)
                  ListTile(
                    leading: const Icon(Icons.emergency_outlined),
                    title: Text(l10n.emergencyDrillConfirmed(drill.confirmedMemberCount)),
                    subtitle: Text(drill.startedAt),
                    trailing: drill.isComplete
                        ? null
                        : TextButton(
                            onPressed: () => controller.completeDrill(drill.drillId),
                            child: Text(l10n.emergencyCompleteDrill),
                          ),
                  ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.notifications_active_outlined),
                  label: Text(l10n.emergencyStartDrill),
                  onPressed: controller.isLoading ? null : controller.startDrill,
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  icon: const Icon(Icons.download_outlined),
                  label: Text(l10n.emergencyExportProof),
                  onPressed: () async {
                    final bytes = await controller.exportProof();
                    if (bytes != null) {
                      await FilePicker.saveFile(
                        fileName: 'emergency-proof-${widget.organizationId}.txt',
                        bytes: Uint8List.fromList(bytes),
                      );
                    }
                  },
                ),
              ],
            ),
    );
  }

  void _showIssuedKitDialog(BuildContext context, IssuedEmergencyKit kit) {
    final l10n = context.l10n;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Text(kit.label),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.emergencyCodesWarning,
                style: TextStyle(
                  color: Theme.of(dialogContext).colorScheme.error,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Text(l10n.emergencyRecoveryCode(kit.recoveryCode)),
              const SizedBox(height: 8),
              for (final code in kit.codes) SelectableText(code),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.copy_all_outlined),
            label: Text(l10n.emergencyCopyAll),
            onPressed: () => Clipboard.setData(ClipboardData(text: kit.printable)),
          ),
          TextButton.icon(
            icon: const Icon(Icons.share_outlined),
            label: Text(l10n.emergencyShare),
            onPressed: () async {
              await FilePicker.saveFile(
                fileName: 'emergency-kit-${kit.kitId}.txt',
                bytes: Uint8List.fromList(kit.printable.codeUnits),
              );
            },
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(MaterialLocalizations.of(dialogContext).okButtonLabel),
          ),
        ],
      ),
    );
  }
}
