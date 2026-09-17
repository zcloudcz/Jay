import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../core/network/signalr_client.dart';
import '../../shared/widgets/avatar.dart';
import '../contacts/contacts_controller.dart';
import 'chat_list_controller.dart';

/// Live conversations from the device database, including offline history.
class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});
  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  bool _loading = true;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await Future.wait([
        context.read<ChatListController>().loadConversations(),
        context.read<ContactsController>().loadContacts(),
      ]);
      if (mounted) {
        setState(() {
          _loading = false;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Unable to load conversations.';
        });
      }
    }
  }

  Future<void> _connect() async {
    try {
      await context.read<SignalRClient>().connect();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cannot connect. Check the network and retry.'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ChatListController>();
    final contacts = context.watch<ContactsController>().contacts;
    final network = context.watch<SignalRClient>();
    final rows = controller.conversations;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Jay'),
        actions: [
          IconButton(
            icon: const Icon(Icons.group_add_outlined),
            tooltip: 'New group',
            onPressed: () => context.push('/groups/create'),
          ),
          IconButton(
            icon: const Icon(Icons.qr_code),
            tooltip: 'My identity',
            onPressed: () => context.push('/settings/identity'),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: Column(
        children: [
          if (!network.connected)
            MaterialBanner(
              content: const Text(
                'Offline — your history is available on this device.',
              ),
              actions: [
                TextButton(onPressed: _connect, child: const Text('Reconnect')),
              ],
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null || controller.error != null
                ? Center(
                    child: TextButton(
                      onPressed: _load,
                      child: Text(
                        _error ?? 'Unable to load conversations. Retry',
                      ),
                    ),
                  )
                : rows.isEmpty
                ? Center(
                    // First-run users looked for a place to enter a friend's
                    // code and found none: the only route was the unlabeled
                    // chat FAB. Give the empty state an explicit action.
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'No conversations yet. Add a contact to start.',
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: () => context.push('/contacts'),
                          icon: const Icon(Icons.person_add_rounded),
                          label: const Text('Add contact'),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (context, index) {
                      final row = rows[index];
                      final matches = contacts.where(
                        (c) => c.deviceId == row.id,
                      );
                      final contact = matches.isEmpty ? null : matches.first;
                      final title =
                          row.title ??
                          contact?.displayName ??
                          contact?.userHandle ??
                          row.id;
                      return ListTile(
                        leading: LetterAvatar(name: title),
                        title: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          row.type == 'group'
                              ? 'Group conversation'
                              : 'Encrypted conversation',
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (row.lastMessageAt != null)
                              Text(
                                DateFormat.Hm().format(
                                  row.lastMessageAt!.toLocal(),
                                ),
                              ),
                            if (row.unreadCount > 0)
                              Badge(label: Text('${row.unreadCount}')),
                          ],
                        ),
                        onTap: () => context.push('/chats/${row.id}'),
                      );
                    },
                  ),
          ),
        ],
      ),
      // Labeled FAB: an icon-only bubble did not read as "add contact / start
      // chat" next to the similar-looking "New group" action in the app bar.
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/contacts'),
        tooltip: 'New chat',
        icon: const Icon(Icons.chat_rounded),
        label: const Text('New chat'),
      ),
    );
  }
}
