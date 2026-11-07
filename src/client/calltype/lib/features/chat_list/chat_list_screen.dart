import 'dart:async';

import 'package:calltype_core/network/group_dtos.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../core/network/signalr_client.dart';
import '../../l10n/l10n.dart';
import '../../shared/widgets/avatar.dart';
import '../../shared/widgets/bot_badge.dart';
import '../../shared/widgets/main_navigation_bar.dart';
import '../contacts/contacts_controller.dart';
import '../devices/device_service.dart';
import '../devices/devices_screen.dart' show LinkWebButton;
import '../mute/mute_controller.dart';
import '../mute/mute_dialog.dart';
import '../notifications/notifications_screen.dart';
import '../organization/business_banner.dart';
import 'chat_list_controller.dart';

/// Live conversations from the device database, including offline history.
class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});
  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  bool _loading = true;
  bool _error = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Mute icons are a nicety: a failed GET /mutes must not turn the whole
    // list into an error, so it runs on the side and errors are dropped.
    final mutes = context.read<MuteController?>();
    if (mutes != null) unawaited(mutes.load().catchError((Object _) {}));
    try {
      await Future.wait([
        context.read<ChatListController>().loadConversations(),
        context.read<ContactsController>().loadContacts(),
      ]);
      if (mounted) {
        setState(() {
          _loading = false;
          _error = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = true;
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
          SnackBar(content: Text(context.l10n.chatListCannotConnect)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ChatListController>();
    final contacts = context.watch<ContactsController>().contacts;
    final network = context.watch<SignalRClient>();
    final devices = context.watch<DeviceService>();
    final rows = controller.conversations;
    // Optional so screens pumped without it (older tests) still build.
    final mutes = context.watch<MuteController?>();
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Jay'),
        actions: [
          // Spec 2026-11-08-chat-extras: searches this device's history.
          IconButton(
            key: const ValueKey('chat-list-search'),
            icon: const Icon(Icons.search_rounded),
            tooltip: l10n.searchMessagesTooltip,
            onPressed: () => context.push('/search'),
          ),
          // A companion would become a group member on its own; groups are
          // created from the primary (the server refuses it too).
          if (!devices.isCompanion)
            IconButton(
              icon: const Icon(Icons.group_add_outlined),
              tooltip: l10n.chatListNewGroup,
              onPressed: () => context.push('/groups/create'),
            ),
          // Link UX A2: linking the web or a computer was three levels deep
          // in Settings; it is what people look for on this screen.
          const LinkWebButton(),
          IconButton(
            icon: const Icon(Icons.qr_code),
            tooltip: l10n.chatListMyIdentity,
            onPressed: () => context.push('/settings/identity'),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: l10n.settingsTitle,
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: Column(
        children: [
          if (!network.connected)
            MaterialBanner(
              content: Text(l10n.chatListOffline),
              actions: [
                TextButton(onPressed: _connect, child: Text(l10n.chatListReconnect)),
              ],
            ),
          // Web only, until answered or dismissed: the browser allows the
          // permission prompt only from a click (spec section 2).
          const NotificationPermissionBanner(),
          // Decision 7: "cannot verify" deletes nothing and says so; a
          // verified removal says that the chats were deleted.
          if (devices.status != CompanionStatus.ok)
            ListTile(
              leading: const Icon(Icons.warning_amber_rounded),
              title: Text(
                devices.status == CompanionStatus.removed
                    ? l10n.devicesRemovedNotice
                    : l10n.devicesCannotVerify,
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error || controller.error != null
                ? Center(
                    child: TextButton(
                      onPressed: _load,
                      child: Text(
                        l10n.chatListLoadFailed,
                        textAlign: TextAlign.center,
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
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Text(
                            l10n.chatListEmpty,
                            textAlign: TextAlign.center,
                          ),
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: () => context.push('/contacts'),
                          icon: const Icon(Icons.person_add_rounded),
                          label: Text(l10n.chatListAddContact),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (context, index) {
                      final row = rows[index];
                      final muteMode = mutes?.modeOf(row.id) ?? MuteMode.off;
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
                        title: NameWithBotBadge(
                          name: title,
                          isBot: contact?.isBot ?? false,
                        ),
                        subtitle: Row(
                          children: [
                            if (row.organizationName != null) ...[
                              BusinessBadge(
                                organizationName: row.organizationName!,
                              ),
                              const SizedBox(width: 4),
                            ],
                            Flexible(
                              child: Text(
                                row.type == 'group'
                                    ? l10n.chatListGroupConversation
                                    : l10n.chatListEncryptedConversation,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (row.lastMessageAt != null)
                              Text(
                                DateFormat.Hm(l10n.localeName).format(
                                  row.lastMessageAt!.toLocal(),
                                ),
                              ),
                            if (muteMode != MuteMode.off)
                              Icon(
                                muteIcon(muteMode),
                                size: 16,
                                semanticLabel: muteMode == MuteMode.bots
                                    ? l10n.muteStateBots
                                    : l10n.muteStateAll,
                              ),
                            if (row.unreadCount > 0)
                              Badge(
                                label: Text('${row.unreadCount}'),
                                // A muted chat keeps its count (the user
                                // may still want to know) but greyed out,
                                // like the app badge that ignores it.
                                backgroundColor: muteMode == MuteMode.off
                                    ? null
                                    : Theme.of(context).disabledColor,
                              ),
                          ],
                        ),
                        onTap: () => context.push('/chats/${row.id}'),
                        // Same dialog as the bell in the chat header.
                        onLongPress: mutes == null
                            ? null
                            : () => editMute(
                                context,
                                conversationId: row.id,
                                group: row.type == 'group',
                              ),
                      );
                    },
                  ),
          ),
        ],
      ),
      // Labeled FAB: an icon-only bubble did not read as "add contact / start
      // chat" next to the similar-looking "New group" action in the app bar.
      bottomNavigationBar: const MainNavigationBar(current: MainTab.chats),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/contacts'),
        tooltip: l10n.chatListNewChat,
        icon: const Icon(Icons.chat_rounded),
        label: Text(l10n.chatListNewChat),
      ),
    );
  }
}
