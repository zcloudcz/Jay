import 'package:calltype_core/network/channel_dtos.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/l10n.dart';
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
          SnackBar(content: Text(channelErrorMessage(context.l10n, error))),
        );
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.l10n.channelTitle)),
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
                  text: context.l10n.channelErrorBlocked,
                  action: context.l10n.channelProfileBlockedChannels,
                  onAction: () => context.push('/channels/blocked'),
                );
              }
              if (error != null) {
                return _Message(
                  text: context.l10n.channelProfileNotFound,
                  action: context.l10n.commonRetry,
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
    final l10n = context.l10n;
    // Local state wins once the user acted here; the fetched profile is a
    // snapshot from before the tap.
    final local = controller.channel(info.channelId);
    final following = local?.isFollowing ?? false;
    final role = local?.role ?? info.role;
    // Edited here a moment ago → the local row is newer than the snapshot.
    final name = local?.name ?? info.name;
    final description = local?.description ?? info.description;
    final link = '$channelLinkPrefix${info.handle}';
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(name, style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        SelectableText(info.handle, style: theme.textTheme.bodySmall),
        const SizedBox(height: 12),
        if (description.isNotEmpty) Text(description),
        const SizedBox(height: 12),
        Text(
          l10n.channelFollowers(info.followerCount),
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
          child: Text(following ? l10n.channelUnfollow : l10n.channelFollow),
        ),
        if (local != null)
          TextButton(
            onPressed: () => context.push('/channels/feed/${info.channelId}'),
            child: Text(l10n.channelOpenPosts),
          ),
        // The server lets owner AND admin edit the profile; managing admins
        // and deleting the channel are owner-only.
        if (role != null)
          TextButton(
            onPressed: _busy
                ? null
                : () => _edit(context, controller, info, name, description),
            child: Text(l10n.channelEdit),
          ),
        if (role == 'owner') ...[
          TextButton(
            onPressed: () => context.push('/channels/admins/${info.channelId}'),
            child: Text(l10n.channelManageAdmins),
          ),
          TextButton(
            onPressed: _busy ? null : () => _delete(context, controller, info),
            child: Text(
              l10n.channelDelete,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        ],
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
              label: Text(l10n.channelCopyLink),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                await Clipboard.setData(ClipboardData(text: link));
                messenger.showSnackBar(
                  SnackBar(content: Text(l10n.channelLinkCopied)),
                );
              },
            ),
            TextButton.icon(
              icon: const Icon(Icons.share_rounded),
              label: Text(l10n.commonShare),
              onPressed: () =>
                  SharePlus.instance.share(ShareParams(text: link)),
            ),
          ],
        ),
        const Divider(height: 32),
        TextButton.icon(
          icon: const Icon(Icons.flag_outlined),
          label: Text(l10n.channelReportChannel),
          onPressed: () => reportChannelDialog(context, info.channelId),
        ),
        TextButton.icon(
          icon: const Icon(Icons.block_rounded),
          label: Text(l10n.channelBlock),
          onPressed: _busy ? null : () => _block(context, controller, info),
        ),
      ],
    );
  }

  Future<void> _edit(
    BuildContext context,
    ChannelsController controller,
    ChannelInfo info,
    String name,
    String description,
  ) async {
    // Plain variables instead of controllers — see reportChannelDialog.
    var newName = name;
    var newDescription = description;
    final l10n = context.l10n;
    final save = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.channelEdit),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              initialValue: name,
              maxLength: 64,
              onChanged: (v) => newName = v,
              decoration: InputDecoration(labelText: l10n.channelNameLabel),
            ),
            TextFormField(
              initialValue: description,
              maxLength: 512,
              minLines: 2,
              maxLines: 5,
              onChanged: (v) => newDescription = v,
              decoration: InputDecoration(
                labelText: l10n.channelDescriptionLabel,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.commonSave),
          ),
        ],
      ),
    );
    newName = newName.trim();
    newDescription = newDescription.trim();
    if (save != true || newName.isEmpty) return;
    await _run(
      () => controller.updateChannel(
        info.channelId,
        // PATCH semantics: null = unchanged, so only edited fields are sent.
        name: newName == name ? null : newName,
        description: newDescription == description ? null : newDescription,
      ),
    );
  }

  Future<void> _delete(
    BuildContext context,
    ChannelsController controller,
    ChannelInfo info,
  ) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.channelDeleteConfirmTitle(info.name)),
        content: Text(l10n.channelDeleteConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    var deleted = false;
    await _run(() async {
      await controller.deleteChannel(info.channelId);
      deleted = true;
    });
    // Leave only on success — after a failure the snackbar must stay visible.
    if (deleted && context.mounted) context.go('/updates');
  }

  Future<void> _block(
    BuildContext context,
    ChannelsController controller,
    ChannelInfo info,
  ) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.channelBlockConfirmTitle(info.name)),
        content: Text(l10n.channelBlockConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.channelBlockConfirm),
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
