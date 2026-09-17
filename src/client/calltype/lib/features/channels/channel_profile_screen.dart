import 'package:calltype_core/network/channel_dtos.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import 'channel_notice.dart';
import 'channel_screen.dart' show reportChannelDialog;
import 'channels_controller.dart';

/// Public profile of a channel — the landing page of
/// `calltype://channel/<handle>` links and channel QR codes.
///
/// Shows only what the server exposes publicly: name, description and the
/// follower COUNT. Followers are anonymous to the admins and to each other.
class ChannelProfileScreen extends StatefulWidget {
  const ChannelProfileScreen({super.key, required this.handle});
  final String handle;

  @override
  State<ChannelProfileScreen> createState() => _ChannelProfileScreenState();
}

class _ChannelProfileScreenState extends State<ChannelProfileScreen> {
  late Future<ChannelInfo> _info;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _info = context.read<ChannelsController>().openByHandle(widget.handle);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is ChannelBlockedException
                  ? '$error'
                  : 'That did not work. Check the connection.',
            ),
          ),
        );
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Channel')),
    body: Column(
      children: [
        const ChannelPublicNotice(),
        Expanded(
          child: FutureBuilder<ChannelInfo>(
            future: _info,
            builder: (context, snapshot) {
              final error = snapshot.error;
              if (error is ChannelBlockedException) {
                // A link must not reopen a blocked channel (plan §7.5); the
                // only way back is an explicit unblock.
                return _Message(
                  text: '$error',
                  action: 'Blocked channels',
                  onAction: () => context.push('/channels/blocked'),
                );
              }
              if (error != null) {
                return _Message(
                  text: 'Channel not found. Check the link and connection.',
                  action: 'Retry',
                  onAction: () => setState(() {
                    _info = context.read<ChannelsController>().openByHandle(
                      widget.handle,
                    );
                  }),
                );
              }
              final info = snapshot.data;
              if (info == null) {
                return const Center(child: CircularProgressIndicator());
              }
              return _profile(context, info);
            },
          ),
        ),
      ],
    ),
  );

  Widget _profile(BuildContext context, ChannelInfo info) {
    final controller = context.watch<ChannelsController>();
    final theme = Theme.of(context);
    // Local state wins once the user acted here; the fetched profile is a
    // snapshot from before the tap.
    final local = controller.channel(info.channelId);
    final following = local?.isFollowing ?? false;
    final canPublish = (local?.role ?? info.role) != null;
    final link = '$channelLinkPrefix${info.handle}';
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(info.name, style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        SelectableText(info.handle, style: theme.textTheme.bodySmall),
        const SizedBox(height: 12),
        if (info.description.isNotEmpty) Text(info.description),
        const SizedBox(height: 12),
        Text(
          '${info.followerCount} followers',
          style: theme.textTheme.labelLarge,
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy
              ? null
              : () => _run(
                  () => following
                      ? controller.unfollow(info.channelId)
                      : controller.follow(info),
                ),
          child: Text(following ? 'Unfollow' : 'Follow'),
        ),
        if (local != null)
          TextButton(
            onPressed: () => context.push('/channels/feed/${info.channelId}'),
            child: const Text('Open posts'),
          ),
        if (canPublish && (local?.role ?? info.role) == 'owner')
          TextButton(
            onPressed: () => context.push('/channels/admins/${info.channelId}'),
            child: const Text('Manage admins'),
          ),
        const Divider(height: 32),
        Center(
          child: Container(
            color: Colors.white,
            padding: const EdgeInsets.all(12),
            child: QrImageView(data: link, size: 200),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton.icon(
              icon: const Icon(Icons.copy_rounded),
              label: const Text('Copy link'),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                await Clipboard.setData(ClipboardData(text: link));
                messenger.showSnackBar(
                  const SnackBar(content: Text('Channel link copied')),
                );
              },
            ),
            TextButton.icon(
              icon: const Icon(Icons.share_rounded),
              label: const Text('Share'),
              onPressed: () =>
                  SharePlus.instance.share(ShareParams(text: link)),
            ),
          ],
        ),
        const Divider(height: 32),
        TextButton.icon(
          icon: const Icon(Icons.flag_outlined),
          label: const Text('Report channel'),
          onPressed: () => reportChannelDialog(context, info.channelId),
        ),
        TextButton.icon(
          icon: const Icon(Icons.block_rounded),
          label: const Text('Block channel'),
          onPressed: _busy ? null : () => _block(context, controller, info),
        ),
      ],
    );
  }

  Future<void> _block(
    BuildContext context,
    ChannelsController controller,
    ChannelInfo info,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Block ${info.name}?'),
        content: const Text(
          'You will stop following it, its posts are removed from this '
          'device and its links will no longer open. You can unblock it in '
          'Settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Block'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(
      () => controller.block(
        channelId: info.channelId,
        handle: info.handle,
        name: info.name,
      ),
    );
    if (context.mounted) context.go('/updates');
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.text,
    required this.action,
    required this.onAction,
  });
  final String text;
  final String action;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(onPressed: onAction, child: Text(action)),
        ],
      ),
    ),
  );
}
