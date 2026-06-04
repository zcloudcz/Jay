import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/avatar.dart';

/// Main screen showing all conversations, ordered by most recent message.
///
/// Currently renders sample placeholder data — the real conversation list
/// will be populated from the local Drift database in Phase 4 when the
/// SignalR message relay is integrated and messages start flowing.
///
/// Layout follows the standard messaging app pattern: scrollable list with
/// avatar, name, last message preview, and timestamp per tile. FAB opens
/// the contacts screen to start new conversations.
class ChatListScreen extends StatelessWidget {
  const ChatListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('CallType'),
        actions: [
          // QR scanner for in-person contact exchange — navigates to the
          // scan screen where the camera feed + QR decoder live.
          IconButton(
            icon: const Icon(Icons.qr_code_scanner_rounded),
            tooltip: 'Scan QR code',
            onPressed: () => context.push('/contacts/scan'),
          ),
          IconButton(
            icon: const Icon(Icons.settings_rounded),
            tooltip: 'Settings',
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: _sampleChats.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.chat_bubble_outline_rounded,
                    size: 64,
                    color: colorScheme.onSurfaceVariant.withAlpha(100),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No conversations yet',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Tap + to start a new chat',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            )
          : ListView.builder(
              itemCount: _sampleChats.length,
              itemBuilder: (context, index) {
                final chat = _sampleChats[index];
                return _ChatTile(chat: chat);
              },
            ),
      // FAB to start a new conversation from the contacts list.
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push('/contacts'),
        tooltip: 'New chat',
        child: const Icon(Icons.chat_rounded),
      ),
    );
  }
}

/// Single row in the chat list, showing contact info and last message preview.
class _ChatTile extends StatelessWidget {
  const _ChatTile({required this.chat});

  final _SampleChat chat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      leading: LetterAvatar(name: chat.name),
      title: Text(
        chat.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        chat.lastMessage,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: Text(
        chat.time,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      onTap: () => context.push('/chats/${chat.id}'),
    );
  }
}

/// Placeholder chat data for visual development and testing.
///
/// These sample entries let us verify layout, scrolling, and navigation
/// before the real database integration is ready. Will be removed when
/// the chat list reads from [AppDatabase] in Phase 4.
class _SampleChat {
  const _SampleChat({
    required this.id,
    required this.name,
    required this.lastMessage,
    required this.time,
  });

  final String id;
  final String name;
  final String lastMessage;
  final String time;
}

const _sampleChats = [
  _SampleChat(
    id: '1',
    name: 'Alice',
    lastMessage: 'See you tomorrow!',
    time: '10:30',
  ),
  _SampleChat(
    id: '2',
    name: 'Bob',
    lastMessage: 'The document is ready.',
    time: '09:15',
  ),
  _SampleChat(
    id: '3',
    name: 'Charlie',
    lastMessage: 'Thanks for the update.',
    time: 'Yesterday',
  ),
];
