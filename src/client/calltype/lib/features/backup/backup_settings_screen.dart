import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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

    return Scaffold(
      appBar: AppBar(title: const Text('Cloud Backup')),
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
                        Text(
                          'End-to-End Encrypted',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Message history, embedded attachments and contacts are backed up; '
                      'external files and live encryption sessions are not included. '
                      'Your backup is encrypted with a passphrase that only '
                      'you know. The server never sees your messages or contacts '
                      'in plaintext.\n\n'
                      'If you forget your passphrase, your backup cannot be '
                      'recovered. There is no reset option — this is by design '
                      'for your security.',
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
              decoration: const InputDecoration(
                labelText: 'Backup passphrase',
                hintText: 'Choose a strong passphrase',
                prefixIcon: Icon(Icons.lock_outline),
                border: OutlineInputBorder(),
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
              'Max file size: ${kBackupMaxFileBytes ~/ (1024 * 1024)} MB · '
              'Up to $kBackupMaxPerAccount backups stored at once',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),

            // -- Existing backups (delete to free a slot) -------------------------
            if (controller.backups.isNotEmpty) ...[
              Text('Stored backups', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              ...controller.backups.map(
                (b) => Card(
                  child: ListTile(
                    leading: const Icon(Icons.folder_zip_outlined),
                    title: Text('${((b['sizeBytes'] as num) / 1024).round()} KB'),
                    subtitle: Text(b['createdAt'].toString()),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
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
                label: const Text('Create Backup'),
              ),
              OutlinedButton.icon(
                onPressed: () => controller.restore(_passphraseController.text),
                icon: const Icon(Icons.restore),
                label: const Text('Restore latest backup'),
              ),
            ],

            // Progress indicator during encrypt/upload phases.
            if (controller.isBusy) ...[
              LinearProgressIndicator(value: controller.progress),
              const SizedBox(height: 12),
              Text(
                controller.status == BackupStatus.encrypting
                    ? 'Encrypting your data...'
                    : controller.status == BackupStatus.uploading
                    ? 'Uploading encrypted backup...'
                    : 'Restoring encrypted backup...',
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
                          controller.completionMessage,
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
                          Text(
                            'Backup failed',
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: colorScheme.onErrorContainer,
                            ),
                          ),
                        ],
                      ),
                      if (controller.error != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          controller.error!,
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
                        label: const Text('Try Again'),
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
