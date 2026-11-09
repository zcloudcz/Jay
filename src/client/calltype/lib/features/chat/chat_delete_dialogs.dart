import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../contacts/contacts_controller.dart';
import '../mute/mute_controller.dart';
import '../mute/mute_dialog.dart';
import 'chat_deletion.dart';

/// Menus and dialogs to delete chats and contacts and to leave groups
/// (spec 2026-11-09-delete-chats-contacts D1 to D7). Shared by the chat
/// list, the chat's app bar menu and the contact list.

enum _ChatDeleteChoice { delete, leave }

void _snack(ScaffoldMessengerState? messenger, String text) =>
    messenger?.showSnackBar(SnackBar(content: Text(text)));

/// Asks before deleting [conversationId] on this identity (D1). A group
/// also offers "Leave group and delete" (D3/D5). Returns true when the chat
/// is gone, so a caller showing that chat can leave it.
Future<bool> confirmDeleteChat(
  BuildContext context, {
  required String conversationId,
  required bool group,
  required bool business,
}) async {
  final service = context.read<ChatDeletionService?>();
  if (service == null) return false;
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final choice = await showDialog<_ChatDeleteChoice>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('delete-chat-dialog'),
      title: Text(l10n.chatDeleteChatTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(group ? l10n.chatDeleteGroupChatBody : l10n.chatDeleteChatBody),
          // D6: deleting is local only; the organization's archive stays.
          if (business) ...[
            const SizedBox(height: 12),
            Text(
              l10n.chatDeleteBusinessNote,
              key: const ValueKey('delete-chat-business-note'),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(l10n.commonCancel),
        ),
        if (group)
          TextButton(
            key: const ValueKey('delete-chat-leave'),
            onPressed: () =>
                Navigator.of(dialogContext).pop(_ChatDeleteChoice.leave),
            child: Text(l10n.chatLeaveAndDelete),
          ),
        FilledButton(
          key: const ValueKey('delete-chat-confirm'),
          onPressed: () =>
              Navigator.of(dialogContext).pop(_ChatDeleteChoice.delete),
          child: Text(l10n.chatDeleteChat),
        ),
      ],
    ),
  );
  switch (choice) {
    case null:
      return false;
    case _ChatDeleteChoice.delete:
      await service.deleteChat(conversationId);
      _snack(messenger, l10n.chatDeleted);
      return true;
    case _ChatDeleteChoice.leave:
      return _leave(service, messenger, l10n, conversationId);
  }
}

/// Asks before leaving group [groupId] (D5); after leaving, the chat is
/// deleted here and on the other own devices. Returns true when it left.
Future<bool> confirmLeaveGroup(
  BuildContext context, {
  required String groupId,
  required bool business,
}) async {
  final service = context.read<ChatDeletionService?>();
  if (service == null) return false;
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('leave-group-dialog'),
      title: Text(l10n.chatLeaveGroupTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.chatLeaveGroupBody),
          if (business) ...[
            const SizedBox(height: 12),
            Text(l10n.chatDeleteBusinessNote),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          key: const ValueKey('leave-group-confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(l10n.chatLeaveGroup),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;
  return _leave(service, messenger, l10n, groupId);
}

Future<bool> _leave(
  ChatDeletionService service,
  ScaffoldMessengerState? messenger,
  AppLocalizations l10n,
  String groupId,
) async {
  switch (await service.leaveGroup(groupId)) {
    case LeaveGroupResult.left:
      _snack(messenger, l10n.chatDeleted);
      return true;
    case LeaveGroupResult.lastAdmin:
      _snack(messenger, l10n.chatLeaveGroupLastAdmin);
      return false;
    case LeaveGroupResult.failed:
      _snack(messenger, l10n.chatLeaveGroupFailed);
      return false;
  }
}

/// What [confirmDeleteContact] did.
enum ContactDeletion { cancelled, contactOnly, withChat }

/// Asks before deleting the contact [deviceId] (D4), with "Also delete the
/// chat" ticked by default.
Future<ContactDeletion> confirmDeleteContact(
  BuildContext context, {
  required String deviceId,
  required String name,
}) async {
  final contacts = context.read<ContactsController>();
  final chats = context.read<ChatDeletionService?>();
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  var alsoChat = true;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        key: const ValueKey('delete-contact-dialog'),
        title: Text(l10n.contactDeleteTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.contactDeleteBody(name)),
            if (chats != null)
              CheckboxListTile(
                key: const ValueKey('delete-contact-also-chat'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: alsoChat,
                onChanged: (value) => setState(() => alsoChat = value ?? true),
                title: Text(l10n.contactDeleteAlsoChat),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            key: const ValueKey('delete-contact-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.contactDelete),
          ),
        ],
      ),
    ),
  );
  if (confirmed != true) return ContactDeletion.cancelled;
  await contacts.deleteContact(deviceId);
  final withChat = alsoChat && chats != null;
  if (withChat) await chats.deleteChat(deviceId);
  _snack(messenger, l10n.contactDeleted);
  return withChat ? ContactDeletion.withChat : ContactDeletion.contactOnly;
}

/// Long press, right click or the overflow button on a chat list row: the
/// actions for one conversation (mute, delete, leave, delete contact).
Future<void> showChatActions(
  BuildContext context, {
  required String conversationId,
  required String title,
  required bool group,
  required bool business,
  required bool hasContact,
}) async {
  final mutes = context.read<MuteController?>();
  final canDelete = context.read<ChatDeletionService?>() != null;
  final l10n = context.l10n;
  final action = await showModalBottomSheet<String>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (mutes != null)
            ListTile(
              key: const ValueKey('chat-action-mute'),
              leading: const Icon(Icons.notifications_off_outlined),
              title: Text(l10n.muteTitle),
              onTap: () => Navigator.of(sheetContext).pop('mute'),
            ),
          if (canDelete)
            ListTile(
              key: const ValueKey('chat-action-delete'),
              leading: const Icon(Icons.delete_outline_rounded),
              title: Text(l10n.chatDeleteChat),
              onTap: () => Navigator.of(sheetContext).pop('delete'),
            ),
          if (canDelete && group)
            ListTile(
              key: const ValueKey('chat-action-leave'),
              leading: const Icon(Icons.logout_rounded),
              title: Text(l10n.chatLeaveGroup),
              onTap: () => Navigator.of(sheetContext).pop('leave'),
            ),
          if (hasContact)
            ListTile(
              key: const ValueKey('chat-action-delete-contact'),
              leading: const Icon(Icons.person_remove_outlined),
              title: Text(l10n.contactDelete),
              onTap: () => Navigator.of(sheetContext).pop('contact'),
            ),
        ],
      ),
    ),
  );
  if (!context.mounted) return;
  switch (action) {
    case 'mute':
      await editMute(context, conversationId: conversationId, group: group);
    case 'delete':
      await confirmDeleteChat(
        context,
        conversationId: conversationId,
        group: group,
        business: business,
      );
    case 'leave':
      await confirmLeaveGroup(
        context,
        groupId: conversationId,
        business: business,
      );
    case 'contact':
      await confirmDeleteContact(
        context,
        deviceId: conversationId,
        name: title,
      );
  }
}
