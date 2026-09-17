import 'package:calltype_core/network/channel_dtos.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

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
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Open channel'),
        content: TextField(
          onChanged: (v) => typed = v,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Channel handle or link',
            hintText: 'CH-XXXX-XXXX or calltype://channel/…',
          ),
          onSubmitted: (v) => Navigator.of(dialogContext).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(typed),
            child: const Text('Open'),
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Updates'),
        actions: [
          IconButton(
            icon: const Icon(Icons.link_rounded),
            tooltip: 'Open channel by handle or link',
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
                          const Text(
                            'You do not follow any channels yet. Open a '
                            'channel from a link, QR code or handle.',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 16),
                          FilledButton.icon(
                            onPressed: () => _openByHandle(context),
                            icon: const Icon(Icons.link_rounded),
                            label: const Text('Open channel'),
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
                          channel.role == null
                              ? channel.handle
                              : '${channel.handle} · ${channel.role}',
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
        label: const Text('New channel'),
      ),
    );
  }
}
