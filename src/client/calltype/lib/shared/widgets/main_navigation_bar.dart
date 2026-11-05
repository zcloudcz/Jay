import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/storage/database.dart';
import '../../features/channels/channels_controller.dart';
import '../../features/chat_list/chat_list_controller.dart';
import '../../features/mute/mute_controller.dart';
import '../../l10n/l10n.dart';

enum MainTab { chats, updates }

/// Bottom navigation shared by the two top-level screens.
///
/// Channels live in their own "Updates" tab — never inside the chat list —
/// because they are public, one-way and NOT end-to-end encrypted; mixing
/// them with private conversations would blur that line for the user.
///
/// A shared widget with `context.go` instead of a shell route: both screens
/// stay ordinary top-level routes, so existing deep links and tests that
/// pump a single screen keep working unchanged.
class MainNavigationBar extends StatelessWidget {
  const MainNavigationBar({super.key, required this.current});

  final MainTab current;

  @override
  Widget build(BuildContext context) {
    // select: only a change of the total rebuilds the bar, not every event.
    final unread = context.select<ChannelsController, int>(
      (c) => c.totalUnread,
    );
    Widget badge(IconData icon) => Badge(
      isLabelVisible: unread > 0,
      label: Text('$unread'),
      child: Icon(icon),
    );
    // Unread private messages, without muted conversations (spec D6: a
    // muted chat must not keep pulling the user back). Nullable lookups:
    // screens pumped alone in tests have no chat list / mute controller.
    final chats = context.watch<ChatListController?>();
    final mutes = context.watch<MuteController?>();
    final rows = chats?.conversations ?? const <Conversation>[];
    final chatUnread =
        mutes?.unreadTotal(rows) ??
        rows.fold<int>(0, (sum, c) => sum + c.unreadCount);
    Widget chatBadge(IconData icon) => Badge(
      isLabelVisible: chatUnread > 0,
      label: Text('$chatUnread'),
      child: Icon(icon),
    );
    return NavigationBar(
      selectedIndex: current.index,
      onDestinationSelected: (index) {
        if (index == current.index) return;
        context.go(index == MainTab.chats.index ? '/chats' : '/updates');
      },
      destinations: [
        NavigationDestination(
          icon: chatBadge(Icons.chat_bubble_outline_rounded),
          selectedIcon: chatBadge(Icons.chat_bubble_rounded),
          label: context.l10n.navChats,
        ),
        NavigationDestination(
          icon: badge(Icons.campaign_outlined),
          // The selected state replaces `icon` entirely, so it needs the
          // badge too — posts keep arriving while Updates is open.
          selectedIcon: badge(Icons.campaign_rounded),
          label: context.l10n.navUpdates,
        ),
      ],
    );
  }
}
