import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import 'backup_controller.dart';

/// Settings screen for creating encrypted cloud backups.
///
/// Allows the user to enter a passphrase and trigger a backup of all
/// local data (contacts, conversations, messages). The passphrase is
/// used to derive an encryption key — it is never sent to the server.
///
/// Visual states:
///   - **Idle:** passphrase input + "Create Backup" button
///   - **Encrypting/Uploading:** progress indicator with status text
///   - **Done:** success confirmation
///   - **Error:** error message with retry option
///
/// This screen requires an authenticated account (optional registration)
/// because cloud storage is only available to registered users. Anonymous
/// devices must export backups manually (future feature).
class BackupSettingsScreen extends StatefulWidget {
  const BackupSettingsScreen({super.key});

  @override
  State<BackupSettingsScreen> createState() => _BackupSettingsScreenState();
}

class _BackupSettingsScreenState extends State<BackupSettingsScreen> {
  final _passphraseController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Load the existing backup list on entry so the user sees what's already
    // stored (and can delete one to free a slot) without creating a new backup first.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<BackupController>().loadBackups();
    });
  }

  /// The server sends an ISO-8601 UTC timestamp; show it in the user's
  /// locale and time zone. Anything unparsable is shown as received.
  String _formatCreatedAt(AppLocalizations l10n, Object? raw) {
    final parsed = DateTime.tryParse('$raw')?.toLocal();
    return parsed == null
        ? '$raw'
        : DateFormat.yMMMd(l10n.localeName).add_Hm().format(parsed);
  }

  @override
  void dispose() {
    _passphraseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<BackupController>();
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = context.l10n;
    final error = backupErrorMessage(l10n, controller);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.backupTitle)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // -- Explanation card -------------------------------------------------
            // Inform the user about how backup encryption works so they
            // understand the security model and the importance of remembering
            // their passphrase.
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.shield_rounded, color: colorScheme.primary),
                        const SizedBox(width: 8),
                        // Expanded: translated headings are longer than the
                        // English one and must wrap instead of overflowing.
                        Expanded(
                          child: Text(
                            l10n.backupEncryptedTitle,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      l10n.backupExplanation,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),

            // -- Passphrase input ------------------------------------------------
            TextField(
              controller: _passphraseController,
              obscureText: true,
              decoration: InputDecoration(
                labelText: l10n.backupPassphraseLabel,
                hintText: l10n.backupPassphraseHintCreate,
                prefixIcon: const Icon(Icons.lock_outline),
                border: const OutlineInputBorder(),
              ),
              // Disable input while a backup is in progress to prevent
              // changing the passphrase mid-operation.
              enabled:
                  controller.status == BackupStatus.idle ||
                  controller.status == BackupStatus.error ||
                  controller.status == BackupStatus.done,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.backupLimits(
                kBackupMaxFileBytes ~/ (1024 * 1024),
                kBackupMaxPerAccount,
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),

            // -- Existing backups (delete to free a slot) -------------------------
            if (controller.backups.isNotEmpty) ...[
              Text(l10n.backupStored, style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              ...controller.backups.map(
                (b) => Card(
                  child: ListTile(
                    leading: const Icon(Icons.folder_zip_outlined),
                    title: Text(
                      l10n.sizeKilobytes(
                        NumberFormat.decimalPattern(
                          l10n.localeName,
                        ).format(((b['sizeBytes'] as num) / 1024).round()),
                      ),
                    ),
                    subtitle: Text(_formatCreatedAt(l10n, b['createdAt'])),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: l10n.backupDelete,
                      onPressed: controller.isBusy
                          ? null
                          : () => controller.deleteBackup(b['id'] as int),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],

            // -- Action button / status display ----------------------------------
            if (controller.status == BackupStatus.idle ||
                controller.status == BackupStatus.done) ...[
              FilledButton.icon(
                onPressed: () {
                  controller.createBackup(_passphraseController.text);
                },
                icon: const Icon(Icons.backup_rounded),
                label: Text(l10n.backupCreate),
              ),
              OutlinedButton.icon(
                onPressed: () => controller.restore(_passphraseController.text),
                icon: const Icon(Icons.restore),
                label: Text(l10n.backupRestoreLatest),
              ),
            ],

            // Progress indicator during encrypt/upload phases.
            if (controller.isBusy) ...[
              LinearProgressIndicator(value: controller.progress),
              const SizedBox(height: 12),
              Text(
                controller.status == BackupStatus.encrypting
                    ? l10n.backupEncrypting
                    : controller.status == BackupStatus.uploading
                    ? l10n.backupUploading
                    : l10n.backupRestoring,
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ],

            // Success confirmation.
            if (controller.status == BackupStatus.done) ...[
              const SizedBox(height: 16),
              Card(
                color: colorScheme.primaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(
                        Icons.check_circle,
                        color: colorScheme.onPrimaryContainer,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          controller.lastOperationWasRestore
                              ? l10n.backupRestored
                              : l10n.backupCreated,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],

            // Error display with retry option.
            if (controller.status == BackupStatus.error) ...[
              const SizedBox(height: 16),
              Card(
                color: colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.error_outline, color: colorScheme.error),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              l10n.backupFailedTitle,
                              style: theme.textTheme.titleSmall?.copyWith(
                                color: colorScheme.onErrorContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (error != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          error,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onErrorContainer,
                          ),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: () {
                          controller.reset();
                        },
                        icon: const Icon(Icons.refresh),
                        label: Text(l10n.backupTryAgain),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
