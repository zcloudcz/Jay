import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'channel_notice.dart';
import 'channels_controller.dart';

/// Settings → Blocked channels. Blocking exists only on this device, so
/// this list is the single place where a block can be lifted; afterwards the
/// channel's link opens again and it can be followed anew.
class BlockedChannelsScreen extends StatelessWidget {
  const BlockedChannelsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ChannelsController>();
    final blocked = controller.blocked;
    return Scaffold(
      appBar: AppBar(title: const Text('Blocked channels')),
      body: Column(
        children: [
          const ChannelPublicNotice(),
          Expanded(
            child: blocked.isEmpty
                ? const Center(child: Text('No blocked channels.'))
                : ListView.builder(
                    itemCount: blocked.length,
                    itemBuilder: (context, index) {
                      final channel = blocked[index];
                      return ListTile(
                        key: ValueKey(channel.channelId),
                        leading: const Icon(Icons.block_rounded),
                        title: Text(channel.name),
                        subtitle: Text(channel.handle),
                        trailing: TextButton(
                          onPressed: () =>
                              controller.unblock(channel.channelId),
                          child: const Text('Unblock'),
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
