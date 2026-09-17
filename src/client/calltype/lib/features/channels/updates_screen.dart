import 'package:calltype_core/network/channel_dtos.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../shared/widgets/avatar.dart';
import '../../shared/widgets/main_navigation_bar.dart';
import 'channel_notice.dart';
import 'channels_controller.dart';

/// The "Updates" tab: channels this device follows or administers.
///
/// Discovery is by link / QR / handle only (plan §7.3) — there is on purpose
/// no catalogue or search here, just "open a channel you were given".
class UpdatesScreen extends StatelessWidget {
  const UpdatesScreen({super.key});

  Future<void> _openByHandle(BuildContext context) async {
    // Plain variable, not a TextEditingController: a controller would have
    // to be disposed while the dialog's exit animation still uses it.
    var typed = '';
    final l10n = context.l10n;
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.channelOpenTitle),
        content: TextField(
          onChanged: (v) => typed = v,
          autofocus: true,
          decoration: InputDecoration(
            labelText: l10n.channelOpenLabel,
            hintText: l10n.channelOpenHint,
          ),
          onSubmitted: (v) => Navigator.of(dialogContext).pop(v),
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
    final text = value?.trim() ?? '';
    if (text.isEmpty || !context.mounted) return;
    final handle = parseChannelLink(text) ?? text.toUpperCase();
    context.push('/channels/profile/${Uri.encodeComponent(handle)}');
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ChannelsController>();
    final channels = controller.channels;
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.navUpdates),
        actions: [
          IconButton(
            icon: const Icon(Icons.link_rounded),
            tooltip: l10n.channelOpenTooltip,
            onPressed: () => _openByHandle(context),
          ),
        ],
      ),
      body: Column(
        children: [
          const ChannelPublicNotice(),
          Expanded(
            child: channels.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            l10n.channelUpdatesEmpty,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 16),
                          FilledButton.icon(
                            onPressed: () => _openByHandle(context),
                            icon: const Icon(Icons.link_rounded),
                            label: Text(l10n.channelOpenTitle),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: channels.length,
                    itemBuilder: (context, index) {
                      final channel = channels[index];
                      return ListTile(
                        key: ValueKey(channel.channelId),
                        leading: LetterAvatar(name: channel.name),
                        title: Text(
                          channel.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          // The role is a server code; unknown future
                          // roles are shown as "admin" rather than raw.
                          channel.role == null
                              ? channel.handle
                              : '${channel.handle} · ${channel.role == 'owner' ? l10n.channelRoleOwner : l10n.channelRoleAdmin}',
                        ),
                        trailing: channel.unreadCount > 0
                            ? Badge(label: Text('${channel.unreadCount}'))
                            : null,
                        onTap: () =>
                            context.push('/channels/feed/${channel.channelId}'),
                      );
                    },
                  ),
          ),
        ],
      ),
      bottomNavigationBar: const MainNavigationBar(current: MainTab.updates),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/channels/create'),
        icon: const Icon(Icons.add_rounded),
        label: Text(l10n.channelNew),
      ),
    );
  }
}
