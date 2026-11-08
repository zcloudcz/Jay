import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:calltype_core/storage/database.dart';
import '../../l10n/l10n.dart';
import 'contacts_controller.dart';

/// Asks for a local nickname for [contact] and stores it. Blank resets it.
Future<void> showRenameContactDialog(
  BuildContext context,
  Contact contact,
) async {
  // Read before the await: the dialog may outlive this context's validity.
  final controller = context.read<ContactsController>();
  final name = await showDialog<String>(
    context: context,
    builder: (_) => _RenameContactDialog(contact: contact),
  );
  if (name != null) await controller.renameContact(contact.deviceId, name);
}

/// A StatefulWidget so the TextEditingController is disposed together with
/// the dialog's element, i.e. only after the exit animation finished (disposing
/// it right after showDialog returns breaks the still-animating TextField).
class _RenameContactDialog extends StatefulWidget {
  const _RenameContactDialog({required this.contact});
  final Contact contact;

  @override
  State<_RenameContactDialog> createState() => _RenameContactDialogState();
}

class _RenameContactDialogState extends State<_RenameContactDialog> {
  late final _name = TextEditingController(text: widget.contact.displayName);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      content: TextField(
        controller: _name,
        autofocus: true,
        maxLength: 60,
        decoration: InputDecoration(
          labelText: l10n.contactRenameLabel,
          helperText: widget.contact.userHandle,
        ),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_name.text),
          child: Text(l10n.commonSave),
        ),
      ],
    );
  }
}
