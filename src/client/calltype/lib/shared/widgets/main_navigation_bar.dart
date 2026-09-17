import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../features/channels/channels_controller.dart';

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
    return NavigationBar(
      selectedIndex: current.index,
      onDestinationSelected: (index) {
        if (index == current.index) return;
        context.go(index == MainTab.chats.index ? '/chats' : '/updates');
      },
      destinations: [
        const NavigationDestination(
          icon: Icon(Icons.chat_bubble_outline_rounded),
          selectedIcon: Icon(Icons.chat_bubble_rounded),
          label: 'Chats',
        ),
        NavigationDestination(
          icon: badge(Icons.campaign_outlined),
          // The selected state replaces `icon` entirely, so it needs the
          // badge too — posts keep arriving while Updates is open.
          selectedIcon: badge(Icons.campaign_rounded),
          label: 'Updates',
        ),
      ],
    );
  }
}
