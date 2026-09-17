import 'package:calltype_core/network/channel_dtos.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/storage/database.dart';
import '../../core/storage/secure_storage.dart';
import '../../shared/widgets/avatar.dart';
import '../../shared/widgets/bot_badge.dart';
import '../contacts/contacts_controller.dart';
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
  String? _error;

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
        _error = channelErrorMessage(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('New channel')),
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
          const Text(
            'Creating a channel requires a registered account, so the '
            'channel is not lost together with this device. Following '
            'channels stays possible without an account.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => context.push('/settings/account'),
            child: const Text('Register or log in'),
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
        decoration: const InputDecoration(labelText: 'Channel name'),
      ),
      TextField(
        controller: _description,
        maxLength: 512,
        minLines: 2,
        maxLines: 5,
        enabled: !_busy,
        decoration: const InputDecoration(labelText: 'Description'),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      FilledButton(
        onPressed: _busy ? null : _create,
        child: const Text('Create channel'),
      ),
    ],
  );
}

/// Owner-only: current admins (with remove) on top, then the local contacts
/// that can be appointed.
///
/// `GET /channels/{id}/admins` is the one place the channel API exposes
/// device ids — to the owner who appointed them. An admin is shown under the
/// name of the matching local contact, or a shortened id when the owner has
/// no such contact (any more).
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

  Future<void> _set(String deviceId, bool admin) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<ChannelsController>().setAdmin(
        widget.channelId,
        deviceId,
        admin,
      );
      messenger.showSnackBar(
        SnackBar(content: Text(admin ? 'Admin added.' : 'Admin removed.')),
      );
      await _reload();
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text(channelErrorMessage(error))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final contacts = context.watch<ContactsController>().contacts;
    final admins = _admins ?? const <ChannelAdminDto>[];
    final adminIds = {for (final a in admins) a.deviceId};
    final candidates = [
      for (final c in contacts)
        if (!adminIds.contains(c.deviceId)) c,
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Channel admins')),
      body: Column(
        children: [
          const ChannelPublicNotice(),
          Expanded(
            child: ListView(
              children: [
                const ListTile(dense: true, title: Text('Current admins')),
                if (admins.isEmpty)
                  ListTile(
                    title: Text(
                      _admins == null ? 'Loading…' : 'No admins yet.',
                    ),
                  ),
                for (final admin in admins)
                  _adminTile(
                    admin.deviceId,
                    contacts
                        .where((c) => c.deviceId == admin.deviceId)
                        .firstOrNull,
                  ),
                const Divider(),
                const ListTile(dense: true, title: Text('Add from contacts')),
                if (candidates.isEmpty)
                  const ListTile(
                    title: Text('Add a contact first to make them an admin.'),
                  ),
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
                    trailing: IconButton(
                      icon: const Icon(Icons.person_add_alt_1_rounded),
                      tooltip: 'Make admin',
                      onPressed: () => _set(contact.deviceId, true),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _adminTile(String deviceId, Contact? contact) {
    // A GUID is unreadable; its first block is enough to tell admins apart.
    final name =
        contact?.displayName ??
        contact?.userHandle ??
        deviceId.split('-').first;
    return ListTile(
      key: ValueKey('admin-$deviceId'),
      leading: LetterAvatar(name: name),
      title: NameWithBotBadge(name: name, isBot: contact?.isBot ?? false),
      subtitle: contact == null ? null : Text(contact.userHandle),
      trailing: IconButton(
        icon: const Icon(Icons.person_remove_alt_1_rounded),
        tooltip: 'Remove admin',
        onPressed: () => _set(deviceId, false),
      ),
    );
  }
}
