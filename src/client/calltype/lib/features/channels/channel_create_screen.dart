import 'package:calltype_core/network/channel_dtos.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/storage/database.dart';
import '../../core/storage/secure_storage.dart';
import '../../shared/widgets/avatar.dart';
import '../../shared/widgets/bot_badge.dart';
import '../contacts/contacts_controller.dart';
import '../../l10n/l10n.dart';
import 'channel_moderation.dart';
import 'channel_notice.dart';
import 'channels_controller.dart';

/// Create a channel.
///
/// Only a device linked to a registered account may own a channel (plan
/// §7.4): ownership hangs on the account so the channel survives the loss of
/// this device. An anonymous device therefore gets an explanation and a way
/// to the existing registration flow instead of a form that could only end
/// in a 403. Following channels needs no account.
class ChannelCreateScreen extends StatefulWidget {
  const ChannelCreateScreen({super.key});

  @override
  State<ChannelCreateScreen> createState() => _ChannelCreateScreenState();
}

class _ChannelCreateScreenState extends State<ChannelCreateScreen> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  late final Future<String?> _accountId = context
      .read<SecureStorage>()
      .getAccountId();
  bool _busy = false;
  Object? _error; // mapped to text in build(), see channelErrorMessage

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final channel = await context.read<ChannelsController>().createChannel(
        name,
        _description.text.trim(),
      );
      if (mounted) {
        context.pushReplacement('/channels/feed/${channel.channelId}');
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.l10n.channelNew)),
    body: Column(
      children: [
        const ChannelPublicNotice(),
        Expanded(
          child: FutureBuilder<String?>(
            future: _accountId,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              return snapshot.data == null ? _gate(context) : _form(context);
            },
          ),
        ),
      ],
    ),
  );

  Widget _gate(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.person_add_alt_1_rounded, size: 48),
          const SizedBox(height: 16),
          Text(
            context.l10n.channelCreateGate,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => context.push('/settings/account'),
            child: Text(context.l10n.channelRegisterOrLogin),
          ),
        ],
      ),
    ),
  );

  Widget _form(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      TextField(
        controller: _name,
        maxLength: 64,
        enabled: !_busy,
        decoration: InputDecoration(labelText: context.l10n.channelNameLabel),
      ),
      TextField(
        controller: _description,
        maxLength: 512,
        minLines: 2,
        maxLines: 5,
        enabled: !_busy,
        decoration: InputDecoration(
          labelText: context.l10n.channelDescriptionLabel,
        ),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            channelErrorMessage(context.l10n, _error!),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      // DSA Art. 14: the rules must be clear and reachable before anyone
      // publishes; creating the channel is the acceptance.
      Text(
        context.l10n.channelCreateRulesAgree,
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const Align(
        alignment: AlignmentDirectional.centerStart,
        child: ChannelRulesLink(),
      ),
      FilledButton(
        onPressed: _busy ? null : _create,
        child: Text(context.l10n.channelCreate),
      ),
    ],
  );
}

/// Owner-only: current admins and publishers (role, BOT badge, change role,
/// remove) on top, then "add by handle" and the local contacts that can be
/// appointed.
///
/// `GET /channels/{id}/admins` is the one place the channel API exposes
/// device ids, to the owner who appointed them. The server now also sends
/// the public handle, display name and isBot; a matching local contact's
/// name wins (the owner chose it), then the server's, then a shortened id.
///
/// WHY "add by handle": a publisher is typically a bot (newsletter) that the
/// owner does not want in their contacts (design D9).
class ChannelAdminsScreen extends StatefulWidget {
  const ChannelAdminsScreen({super.key, required this.channelId});
  final String channelId;

  @override
  State<ChannelAdminsScreen> createState() => _ChannelAdminsScreenState();
}

class _ChannelAdminsScreenState extends State<ChannelAdminsScreen> {
  List<ChannelAdminDto>? _admins; // null = not loaded (yet)

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<ContactsController>().loadContacts();
      _reload();
    });
  }

  Future<void> _reload() async {
    try {
      final admins = await context.read<ChannelsController>().admins(
        widget.channelId,
      );
      if (mounted) setState(() => _admins = admins);
    } catch (_) {
      // Offline / not the owner: appointing below still reports its own error.
    }
  }

  /// [role] null = remove. [changed] picks the "role changed" confirmation.
  Future<void> _set(String deviceId, String? role, {bool changed = false}) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    try {
      await context.read<ChannelsController>().setAdmin(
        widget.channelId,
        deviceId,
        role != null,
        role: role ?? channelRoleAdmin,
      );
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            role == null
                ? l10n.channelAdminRemoved
                : changed
                ? l10n.channelAdminsRoleChanged
                : l10n.channelAdminAdded,
          ),
        ),
      );
      await _reload();
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text(channelErrorMessage(l10n, error))),
      );
    }
  }

  Future<void> _addByHandle() async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final controller = context.read<ChannelsController>();
    // Plain variable, not a TextEditingController: a controller would have
    // to be disposed while the dialog's exit animation still uses it.
    var typed = '';
    final handle = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.channelAdminsAddByHandle),
        content: TextField(
          key: const Key('admin-handle-field'),
          autofocus: true,
          onChanged: (v) => typed = v,
          onSubmitted: (v) => Navigator.of(dialogContext).pop(v),
          decoration: InputDecoration(
            labelText: l10n.channelAdminsHandleLabel,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(typed),
            child: Text(l10n.commonOpen),
          ),
        ],
      ),
    );
    if (handle == null || handle.trim().isEmpty) return;
    final ChannelMemberCandidate? candidate;
    try {
      candidate = await controller.lookupHandle(handle);
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text(channelErrorMessage(l10n, error))),
      );
      return;
    }
    if (candidate == null) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.channelAdminsHandleNotFound)),
      );
      return;
    }
    if (!mounted) return;
    final role = await showDialog<String>(
      context: context,
      builder: (_) => _RoleDialog(candidate: candidate!),
    );
    if (role != null) await _set(candidate.deviceId, role);
  }

  @override
  Widget build(BuildContext context) {
    final contacts = context.watch<ContactsController>().contacts;
    final l10n = context.l10n;
    final admins = _admins ?? const <ChannelAdminDto>[];
    final adminIds = {for (final a in admins) a.deviceId};
    final candidates = [
      for (final c in contacts)
        if (!adminIds.contains(c.deviceId)) c,
    ];
    return Scaffold(
      appBar: AppBar(title: Text(l10n.channelAdminsTitle)),
      body: Column(
        children: [
          const ChannelPublicNotice(),
          Expanded(
            child: ListView(
              children: [
                ListTile(dense: true, title: Text(l10n.channelAdminsCurrent)),
                if (admins.isEmpty)
                  ListTile(
                    title: Text(
                      _admins == null
                          ? l10n.commonLoading
                          : l10n.channelAdminsNone,
                    ),
                  ),
                for (final admin in admins)
                  _adminTile(
                    admin,
                    contacts
                        .where((c) => c.deviceId == admin.deviceId)
                        .firstOrNull,
                  ),
                const Divider(),
                ListTile(
                  key: const Key('admin-add-by-handle'),
                  leading: const Icon(Icons.alternate_email_rounded),
                  title: Text(l10n.channelAdminsAddByHandle),
                  onTap: _addByHandle,
                ),
                ListTile(
                  dense: true,
                  title: Text(l10n.channelAdminsAddFromContacts),
                ),
                if (candidates.isEmpty)
                  ListTile(title: Text(l10n.channelAdminsNoContacts)),
                for (final contact in candidates)
                  ListTile(
                    key: ValueKey(contact.deviceId),
                    leading: LetterAvatar(
                      name: contact.displayName ?? contact.userHandle,
                    ),
                    title: NameWithBotBadge(
                      name: contact.displayName ?? contact.userHandle,
                      isBot: contact.isBot,
                    ),
                    subtitle: Text(contact.userHandle),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.campaign_outlined),
                          tooltip: l10n.channelAdminsMakePublisher,
                          onPressed: () =>
                              _set(contact.deviceId, channelRolePublisher),
                        ),
                        IconButton(
                          icon: const Icon(Icons.person_add_alt_1_rounded),
                          tooltip: l10n.channelAdminsMake,
                          onPressed: () =>
                              _set(contact.deviceId, channelRoleAdmin),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _adminTile(ChannelAdminDto admin, Contact? contact) {
    final l10n = context.l10n;
    // A GUID is unreadable; its first block is enough to tell admins apart.
    final name =
        contact?.displayName ??
        admin.displayName ??
        contact?.userHandle ??
        admin.handle ??
        admin.deviceId.split('-').first;
    final handle = contact?.userHandle ?? admin.handle;
    final role = channelRoleLabel(l10n, admin.role);
    return ListTile(
      key: ValueKey('admin-${admin.deviceId}'),
      leading: LetterAvatar(name: name),
      title: NameWithBotBadge(
        name: name,
        isBot: admin.isBot || (contact?.isBot ?? false),
      ),
      subtitle: Text(handle == null ? role : '$handle · $role'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.manage_accounts_outlined),
            tooltip: l10n.channelAdminsChangeRole,
            onSelected: (role) => _set(admin.deviceId, role, changed: true),
            itemBuilder: (_) => [
              CheckedPopupMenuItem(
                value: channelRoleAdmin,
                checked: !admin.isPublisher,
                child: Text(l10n.channelAdminsRoleAdminHelp),
              ),
              CheckedPopupMenuItem(
                value: channelRolePublisher,
                checked: admin.isPublisher,
                child: Text(l10n.channelAdminsRolePublisherHelp),
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.person_remove_alt_1_rounded),
            tooltip: l10n.channelAdminsRemove,
            onPressed: () => _set(admin.deviceId, null),
          ),
        ],
      ),
    );
  }
}

/// Second step of "add by handle": shows who was found (with the BOT badge)
/// and asks for the role. A bot defaults to publisher: it should never get
/// admin rights by accident (design, Security).
class _RoleDialog extends StatefulWidget {
  const _RoleDialog({required this.candidate});
  final ChannelMemberCandidate candidate;

  @override
  State<_RoleDialog> createState() => _RoleDialogState();
}

class _RoleDialogState extends State<_RoleDialog> {
  late String _role = widget.candidate.isBot
      ? channelRolePublisher
      : channelRoleAdmin;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final candidate = widget.candidate;
    return AlertDialog(
      title: Text(l10n.channelAdminsAddTitle(candidate.name)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          NameWithBotBadge(name: candidate.handle, isBot: candidate.isBot),
          const SizedBox(height: 8),
          RadioGroup<String>(
            groupValue: _role,
            onChanged: (value) => setState(() => _role = value ?? _role),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile<String>(
                  key: const Key('role-admin'),
                  value: channelRoleAdmin,
                  contentPadding: EdgeInsets.zero,
                  title: Text(l10n.channelAdminsRoleAdminHelp),
                ),
                RadioListTile<String>(
                  key: const Key('role-publisher'),
                  value: channelRolePublisher,
                  contentPadding: EdgeInsets.zero,
                  title: Text(l10n.channelAdminsRolePublisherHelp),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_role),
          child: Text(l10n.channelAdminsAdd),
        ),
      ],
    );
  }
}
