import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'backup_controller.dart';

/// Screen for restoring data from an encrypted cloud backup.
///
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
                        Icon(Icons.restore_rounded, color: colorScheme.primary),
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
              onPressed: !controller.isBusy
                  ? () => controller.restore(_passphraseController.text)
                  : null,
              icon: const Icon(Icons.cloud_download_rounded),
              label: const Text('Restore'),
            ),

            if (controller.isBusy)
              LinearProgressIndicator(value: controller.progress),
            if (controller.status == BackupStatus.done)
              Text(controller.completionMessage),
            if (controller.status == BackupStatus.error &&
                controller.error != null) ...[
              const SizedBox(height: 16),
              Card(
                color: colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        color: colorScheme.onErrorContainer,
                      ),
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
