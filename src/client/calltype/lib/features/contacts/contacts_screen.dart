import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:calltype_core/network/channel_dtos.dart' show parseChannelLink;

import '../../l10n/l10n.dart';
import '../../shared/widgets/avatar.dart';
import '../../shared/widgets/bot_badge.dart';
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
      if (mounted) context.read<ContactsController>().loadContacts();
    });
  }

  @override
  Widget build(BuildContext context) {
    final cameraSupported =
        kIsWeb ||
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
    final controller = context.watch<ContactsController>();
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = context.l10n;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.contactsTitle),
        actions: [
          // QR scanner — the primary way to add contacts without leaking
          // metadata. Opens the camera, scans a CallType QR code, and
          // adds the contact on success.
          IconButton(
            icon: Icon(
              cameraSupported
                  ? Icons.qr_code_scanner_rounded
                  : Icons.content_paste_rounded,
            ),
            tooltip: cameraSupported
                ? l10n.contactsScanQr
                : l10n.contactsPasteInvite,
            onPressed: () => cameraSupported
                ? _openQrScanner(context, controller)
                : _showAddDialog(context, controller),
          ),
          // Manual add — for cases where QR scanning isn't practical
          // (e.g. remote contact sharing their handle via text).
          IconButton(
            icon: const Icon(Icons.person_add_rounded),
            tooltip: l10n.contactsAddByHandle,
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
                    l10n.contactsEmptyTitle,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    cameraSupported
                        ? l10n.contactsEmptyHintScan
                        : l10n.contactsEmptyHintPaste,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  // The app-bar icons alone were not discoverable (beta
                  // feedback: "nowhere to paste the code"), so the empty
                  // state repeats both actions as labeled buttons.
                  FilledButton.icon(
                    onPressed: () => _showAddDialog(context, controller),
                    icon: const Icon(Icons.keyboard_rounded),
                    label: Text(l10n.contactsEnterHandleOrInvite),
                  ),
                  if (cameraSupported) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () => _openQrScanner(context, controller),
                      icon: const Icon(Icons.qr_code_scanner_rounded),
                      label: Text(l10n.contactsScanQr),
                    ),
                  ],
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
      // Always-visible labeled entry point for adding a contact by code, also
      // once the list is non-empty and the empty-state buttons are gone.
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddDialog(context, controller),
        icon: const Icon(Icons.person_add_rounded),
        label: Text(l10n.contactsAddContact),
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

    // The scanner also recognises channel QR codes; those are not contacts.
    final channel = result?['channel'];
    if (channel != null) {
      if (context.mounted) context.push('/channels/profile/$channel');
      return;
    }

    if (result != null && context.mounted) {
      try {
        final added = await _previewAndAdd(
          context,
          controller,
          result['handle']!,
          deviceId: result['deviceId'],
        );

        if (added && context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(
            SnackBar(
              content: Text(context.l10n.contactsAdded(result['handle']!)),
            ),
          );
        }
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.l10n.contactsAddFailed)),
          );
        }
      }
    }
  }

  /// Resolves the contact, shows who it is and adds it only after the user
  /// confirms. Returns whether the contact was added.
  ///
  /// WHY a preview step: whether the peer is a bot must be visible BEFORE
  /// the contact is added (bots plan §6) — once added, the user may already
  /// have started typing to what they believed was a person.
  Future<bool> _previewAndAdd(
    BuildContext context,
    ContactsController controller,
    String handle, {
    String? deviceId,
  }) async {
    final preview = await controller.resolveContact(handle, deviceId: deviceId);
    if (!context.mounted) return false;
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.contactsConfirmAddTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            NameWithBotBadge(name: preview.handle, isBot: preview.isBot),
            if (preview.isBot) ...[
              const SizedBox(height: 12),
              Text(l10n.botNotice),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.commonAdd),
          ),
        ],
      ),
    );
    if (confirmed != true) return false;
    await controller.addContact(preview);
    return true;
  }

  /// Shows a dialog to manually enter a contact handle.
  Future<void> _showAddDialog(
    BuildContext context,
    ContactsController controller,
  ) async {
    // A plain variable instead of a TextEditingController: the controller
    // had to be disposed right after the dialog returned, while the dialog's
    // exit animation was still rebuilding the TextField ("used after being
    // disposed" as soon as the preview dialog opens on top of it).
    var typed = '';
    final l10n = context.l10n;

    final handle = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(l10n.contactsAddDialogTitle),
          content: TextField(
            onChanged: (value) => typed = value,
            decoration: InputDecoration(
              labelText: l10n.contactsHandleOrInviteLabel,
              hintText: l10n.contactsHandleOrInviteHint,
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
              child: Text(l10n.commonCancel),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(typed.trim());
              },
              child: Text(l10n.commonAdd),
            ),
          ],
        );
      },
    );

    // A pasted channel link belongs to Updates, not to the contact list.
    final channel = handle == null ? null : parseChannelLink(handle);
    if (channel != null) {
      if (context.mounted) context.push('/channels/profile/$channel');
      return;
    }

    if (handle != null && handle.isNotEmpty && context.mounted) {
      try {
        final added = await _previewAndAdd(context, controller, handle);

        if (added && context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(l10n.contactsAdded(handle))));
        }
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.contactsNotFound)),
          );
        }
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
      title: NameWithBotBadge(name: name, isBot: contact.isBot as bool),
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
        await context.read<ChatListController>().createDirectConversation(
          contact.deviceId,
        );
        if (context.mounted) {
          context.push('/chats/${contact.deviceId}');
        }
      },
    );
  }
}
