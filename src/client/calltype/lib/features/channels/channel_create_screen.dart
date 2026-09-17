import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

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
    } on DioException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = switch (error.response?.statusCode) {
          403 => 'A registered account is required to create a channel.',
          409 => 'You have reached the limit of channels you can own.',
          _ => 'The channel could not be created. Check the connection.',
        };
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

/// Owner-only: grant or revoke the admin role, picking from local contacts.
///
/// ponytail: the plan has no "list admins" endpoint, so the current admins
/// cannot be shown — each contact simply offers both actions (both are
/// idempotent on the server). Show real state once such an endpoint exists.
class ChannelAdminsScreen extends StatefulWidget {
  const ChannelAdminsScreen({super.key, required this.channelId});
  final String channelId;

  @override
  State<ChannelAdminsScreen> createState() => _ChannelAdminsScreenState();
}

class _ChannelAdminsScreenState extends State<ChannelAdminsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<ContactsController>().loadContacts();
    });
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
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Only the channel owner can do this.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final contacts = context.watch<ContactsController>().contacts;
    return Scaffold(
      appBar: AppBar(title: const Text('Channel admins')),
      body: Column(
        children: [
          const ChannelPublicNotice(),
          Expanded(
            child: contacts.isEmpty
                ? const Center(
                    child: Text('Add a contact first to make them an admin.'),
                  )
                : ListView.builder(
                    itemCount: contacts.length,
                    itemBuilder: (context, index) {
                      final contact = contacts[index];
                      final name = contact.displayName ?? contact.userHandle;
                      return ListTile(
                        key: ValueKey(contact.deviceId),
                        leading: LetterAvatar(name: name),
                        title: NameWithBotBadge(
                          name: name,
                          isBot: contact.isBot,
                        ),
                        subtitle: Text(contact.userHandle),
                        trailing: PopupMenuButton<bool>(
                          onSelected: (admin) => _set(contact.deviceId, admin),
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: true,
                              child: Text('Make admin'),
                            ),
                            PopupMenuItem(
                              value: false,
                              child: Text('Remove admin'),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
