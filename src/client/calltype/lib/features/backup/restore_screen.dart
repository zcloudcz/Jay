import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'backup_controller.dart';

/// Screen for restoring data from an encrypted cloud backup.
///
/// Currently a placeholder — the full restore flow requires server-side
/// backup listing and download endpoints that are not yet implemented.
/// The UI is functional: it accepts a passphrase and calls the controller's
/// restore method, which returns a "not yet implemented" message.
///
/// Future implementation will:
///   1. List available backups (date, size) from the server
///   2. Let the user select which backup to restore
///   3. Download + decrypt + import into local DB
///   4. Re-establish Signal Protocol sessions with all contacts
class RestoreScreen extends StatefulWidget {
  const RestoreScreen({super.key});

  @override
  State<RestoreScreen> createState() => _RestoreScreenState();
}

class _RestoreScreenState extends State<RestoreScreen> {
  final _passphraseController = TextEditingController();

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
      appBar: AppBar(title: const Text('Restore Backup')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Informational text explaining the restore process.
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.restore_rounded,
                            color: colorScheme.primary),
                        const SizedBox(width: 8),
                        Text(
                          'Restore from Backup',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Enter the passphrase you used when creating the backup. '
                      'Your data will be downloaded and decrypted locally on '
                      'this device.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),

            // Passphrase input — must match the passphrase used during backup.
            TextField(
              controller: _passphraseController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Backup passphrase',
                hintText: 'Enter your backup passphrase',
                prefixIcon: Icon(Icons.lock_outline),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),

            // Restore button — triggers the restore flow in the controller.
            FilledButton.icon(
              onPressed: controller.status == BackupStatus.idle
                  ? () => controller.restore(_passphraseController.text)
                  : null,
              icon: const Icon(Icons.cloud_download_rounded),
              label: const Text('Restore'),
            ),

            // Error display — currently always shown because restore is
            // not yet implemented. Will show real errors in the future.
            if (controller.status == BackupStatus.error &&
                controller.error != null) ...[
              const SizedBox(height: 16),
              Card(
                color: colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline,
                          color: colorScheme.onErrorContainer),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          controller.error!,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onErrorContainer,
                          ),
                        ),
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
