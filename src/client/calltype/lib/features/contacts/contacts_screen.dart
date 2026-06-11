import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../shared/widgets/avatar.dart';
import '../chat_list/chat_list_controller.dart';
import 'contacts_controller.dart';
import 'qr_scanner_screen.dart';

/// Screen showing all known contacts with options to add new ones.
///
/// Contacts are loaded from the local database on init. New contacts
/// can be added via QR scan (camera) or by entering a handle manually.
/// Tapping a contact navigates to the chat screen for that device.
///
/// Expects a [ContactsController] to be provided via [Provider] in the
/// route builder (see router.dart).
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  @override
  void initState() {
    super.initState();
    // Load contacts on first render. Using addPostFrameCallback to avoid
    // calling notifyListeners during build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ContactsController>().loadContacts();
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ContactsController>();
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Contacts'),
        actions: [
          // QR scanner — the primary way to add contacts without leaking
          // metadata. Opens the camera, scans a CallType QR code, and
          // adds the contact on success.
          IconButton(
            icon: const Icon(Icons.qr_code_scanner_rounded),
            tooltip: 'Scan QR code',
            onPressed: () => _openQrScanner(context, controller),
          ),
          // Manual add — for cases where QR scanning isn't practical
          // (e.g. remote contact sharing their handle via text).
          IconButton(
            icon: const Icon(Icons.person_add_rounded),
            tooltip: 'Add by handle',
            onPressed: () => _showAddDialog(context, controller),
          ),
        ],
      ),
      body: controller.contacts.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.people_outline_rounded,
                    size: 64,
                    color: colorScheme.onSurfaceVariant.withAlpha(100),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No contacts yet',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Scan a QR code or add a handle',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            )
          : ListView.builder(
              itemCount: controller.contacts.length,
              itemBuilder: (context, index) {
                final contact = controller.contacts[index];
                return _ContactTile(contact: contact);
              },
            ),
    );
  }

  /// Opens the QR scanner and adds the scanned contact.
  Future<void> _openQrScanner(
    BuildContext context,
    ContactsController controller,
  ) async {
    // Push the scanner as a full-screen route and wait for the result.
    // The scanner pops with a Map containing 'handle' and optionally 'deviceId'.
    final result = await Navigator.of(context).push<Map<String, String>>(
      MaterialPageRoute(builder: (_) => const QrScannerScreen()),
    );

    if (result != null && context.mounted) {
      await controller.addContactByHandle(
        result['handle']!,
        deviceId: result['deviceId'],
      );

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added ${result['handle']}')),
        );
      }
    }
  }

  /// Shows a dialog to manually enter a contact handle.
  Future<void> _showAddDialog(
    BuildContext context,
    ContactsController controller,
  ) async {
    final handleController = TextEditingController();

    final handle = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Add Contact'),
          content: TextField(
            controller: handleController,
            decoration: const InputDecoration(
              labelText: 'Handle',
              hintText: 'CT-XXXX-XXXX',
            ),
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (value) {
              Navigator.of(dialogContext).pop(value.trim());
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(dialogContext)
                    .pop(handleController.text.trim());
              },
              child: const Text('Add'),
            ),
          ],
        );
      },
    );

    handleController.dispose();

    if (handle != null && handle.isNotEmpty && context.mounted) {
      await controller.addContactByHandle(handle);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added $handle')),
        );
      }
    }
  }
}

/// Single row in the contacts list showing avatar, name, and handle.
class _ContactTile extends StatelessWidget {
  const _ContactTile({required this.contact});

  final dynamic contact;

  @override
  Widget build(BuildContext context) {
    // Use displayName if set, otherwise fall back to handle.
    final name = (contact.displayName as String?) ?? contact.userHandle;

    return ListTile(
      leading: LetterAvatar(name: name),
      title: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        contact.userHandle,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
      // Verified contacts show a blue checkmark — indicates the identity
      // key was verified out-of-band (e.g. safety number comparison).
      trailing: contact.verified
          ? Icon(
              Icons.verified_rounded,
              color: Theme.of(context).colorScheme.primary,
              size: 20,
            )
          : null,
      onTap: () async {
        // Make sure the conversation row exists BEFORE opening the chat —
        // sending and the chat list both rely on it (messages would send
        // fine without it, but the conversation would never appear in
        // the list).
        await context
            .read<ChatListController>()
            .createDirectConversation(contact.deviceId);
        if (context.mounted) {
          context.push('/chats/${contact.deviceId}');
        }
      },
    );
  }
}
