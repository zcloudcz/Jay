import 'dart:convert';

import 'package:calltype_core/network/channel_dtos.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import 'package:calltype_core/storage/database.dart';
import '../../l10n/l10n.dart';
import '../../shared/widgets/bot_badge.dart';
import '../chat/attachment_media.dart';
import '../chat/attachment_sheet.dart';
import '../chat/link_text.dart';
import 'channel_moderation.dart';
import 'channel_notice.dart';
import 'channels_controller.dart';

/// Feed of one channel: newest post at the bottom (WhatsApp style).
///
/// Followers get NO input field: a channel is one-way. Only an owner /
/// admin / publisher sees the compose bar, and nobody while the channel is
/// suspended (the server refuses posting then).
class ChannelScreen extends StatefulWidget {
  const ChannelScreen({super.key, required this.channelId});
  final String channelId;

  @override
  State<ChannelScreen> createState() => _ChannelScreenState();
}

class _ChannelScreenState extends State<ChannelScreen> {
  late final ChannelsController _controller;
  late final Stream<List<ChannelPost>> _posts;
  bool _hasOlder = true;

  @override
  void initState() {
    super.initState();
    _controller = context.read<ChannelsController>();
    // The stream is created once: a new stream per build would resubscribe
    // to the database on every rebuild.
    _posts = _controller.watchPosts(widget.channelId);
    _controller.setOpenChannel(widget.channelId);
    // Best effort — the cached feed stays readable offline.
    _controller.refresh(widget.channelId).catchError((Object _) {});
  }

  @override
  void dispose() {
    _controller.setOpenChannel(null);
    super.dispose();
  }

  Future<void> _loadOlder() async {
    try {
      final more = await _controller.loadOlder(widget.channelId);
      if (mounted) setState(() => _hasOlder = more);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.channelLoadOlderFailed)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // select: the feed must not rebuild for unrelated controller changes
    // (e.g. another channel's unread badge).
    final channel = context.select<ChannelsController, Channel?>(
      (c) => c.channel(widget.channelId),
    );
    final l10n = context.l10n;
    if (channel == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.channelTitle)),
        body: Center(child: Text(l10n.channelNotAvailable)),
      );
    }
    final suspended = channelIsSuspended(channel);
    final canPublish = channel.role != null && !suspended;
    // A publisher may delete only its own posts (server-enforced); owner and
    // admin may delete any.
    final deleteAny =
        channel.role == channelRoleOwner || channel.role == channelRoleAdmin;
    final isPublisher = channel.role == channelRolePublisher;
    // A follower of a suspended channel gets 403 channel_suspended for the
    // feed: show that state instead of a stale cache or an error.
    final feedHidden = suspended && channel.role == null;
    return Scaffold(
      appBar: AppBar(
        title: Text(channel.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline_rounded),
            tooltip: l10n.channelInfo,
            onPressed: () => context.push(
              '/channels/profile/${Uri.encodeComponent(channel.handle)}',
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          const ChannelPublicNotice(),
          if (suspended) ChannelSuspendedBanner(until: channel.suspendedUntil),
          if (feedHidden)
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    l10n.channelSuspendedFeed,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            )
          else
            Expanded(
              child: StreamBuilder<List<ChannelPost>>(
                stream: _posts,
                builder: (context, snapshot) {
                  final posts = snapshot.data ?? const <ChannelPost>[];
                  if (posts.isEmpty) {
                    return Center(child: Text(l10n.channelNoPosts));
                  }
                  // reverse + builder: opens scrolled to the newest post and
                  // only builds visible items; per-post keys keep widget state
                  // (loaded image, scroll position) stable when a post arrives.
                  return ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: posts.length + (_hasOlder ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == posts.length) {
                        return TextButton(
                          onPressed: _loadOlder,
                          child: Text(l10n.channelLoadOlder),
                        );
                      }
                      final post = posts[posts.length - 1 - index];
                      return _PostCard(
                        key: ValueKey(post.postId),
                        post: post,
                        canDelete:
                            deleteAny || (isPublisher && post.publishedHere),
                      );
                    },
                  );
                },
              ),
            ),
          if (canPublish) _ComposeBar(channelId: widget.channelId),
        ],
      ),
    );
  }
}

class _PostCard extends StatelessWidget {
  const _PostCard({super.key, required this.post, required this.canDelete});
  final ChannelPost post;
  final bool canDelete;

  @override
  Widget build(BuildContext context) {
    final controller = context.read<ChannelsController>();
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final poll = post.kind == 'poll' ? ChannelPoll.tryParse(post.body) : null;
    final reactions = (jsonDecode(post.reactions) as Map)
        .cast<String, dynamic>();
    final created = DateTime.tryParse(post.createdAt)?.toLocal();
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 4, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Posts by a bot device are labelled (rule K10, design D10).
            if (post.byBot)
              const Padding(
                padding: EdgeInsetsDirectional.only(bottom: 4),
                child: BotBadge(key: Key('post-bot-badge')),
              ),
            if (post.kind == 'image' && post.attachmentBlobPath != null)
              _PostImage(
                channelId: post.channelId,
                blobPath: post.attachmentBlobPath!,
              ),
            if (poll != null)
              _PollView(post: post, poll: poll)
            else if (post.body.isNotEmpty)
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 8, top: 4),
                child: LinkifiedText(
                  post.body,
                  linkColor: theme.colorScheme.primary,
                  selectable: true,
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 4,
                    children: [
                      for (final entry in reactions.entries)
                        ChoiceChip(
                          visualDensity: VisualDensity.compact,
                          label: Text('${entry.key} ${entry.value}'),
                          selected: post.myReaction == entry.key,
                          onSelected: (_) => _guard(
                            context,
                            () => controller.react(post, entry.key),
                          ),
                        ),
                    ],
                  ),
                ),
                if (created != null)
                  Text(
                    DateFormat.MMMd(l10n.localeName).add_Hm().format(created),
                    style: theme.textTheme.labelSmall,
                  ),
                // Only the six whitelisted emoji — anything else is a 422.
                PopupMenuButton<String>(
                  icon: const Icon(Icons.add_reaction_outlined, size: 20),
                  tooltip: l10n.channelReact,
                  onSelected: (emoji) =>
                      _guard(context, () => controller.react(post, emoji)),
                  itemBuilder: (_) => [
                    for (final emoji in channelReactionEmojis)
                      PopupMenuItem(value: emoji, child: Text(emoji)),
                  ],
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert_rounded, size: 20),
                  tooltip: l10n.channelPostOptions,
                  onSelected: (action) => action == 'report'
                      ? reportChannelDialog(
                          context,
                          post.channelId,
                          postId: post.postId,
                        )
                      : _guard(
                          context,
                          () => controller.deletePost(
                            post.channelId,
                            post.postId,
                          ),
                        ),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'report',
                      child: Text(l10n.channelReportPost),
                    ),
                    if (canDelete)
                      PopupMenuItem(
                        value: 'delete',
                        child: Text(l10n.channelDeletePost),
                      ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Runs a network action and turns a failure into a snackbar instead of an
/// unhandled async error.
Future<void> _guard(
  BuildContext context,
  Future<void> Function() action,
) async {
  final messenger = ScaffoldMessenger.of(context);
  // Captured before the await — the context may be unmounted afterwards.
  final l10n = context.l10n;
  try {
    await action();
  } catch (error) {
    messenger.showSnackBar(
      SnackBar(content: Text(channelErrorMessage(l10n, error))),
    );
  }
}

/// Channel images need the device's Bearer token, so they are fetched through
/// the API client instead of `Image.network`. Stateful so the download runs
/// once per post, not on every rebuild of the feed.
class _PostImage extends StatefulWidget {
  const _PostImage({required this.channelId, required this.blobPath});
  final String channelId;
  final String blobPath;

  @override
  State<_PostImage> createState() => _PostImageState();
}

class _PostImageState extends State<_PostImage> {
  late final Future<Uint8List> _bytes = context
      .read<ChannelsController>()
      .loadAttachment(widget.channelId, widget.blobPath);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsetsDirectional.only(end: 8, bottom: 4),
    child: FutureBuilder<Uint8List>(
      future: _bytes,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return ListTile(
            leading: const Icon(Icons.broken_image_outlined),
            title: Text(context.l10n.channelImageFailed),
          );
        }
        final bytes = snapshot.data;
        if (bytes == null) {
          return const SizedBox(
            height: 160,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            bytes,
            fit: BoxFit.cover,
            // Public, untrusted content: a corrupt file must not throw.
            errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
          ),
        );
      },
    ),
  );
}

/// Poll: options as buttons until this device voted, percentages afterwards
/// (showing totals first would bias the vote). Only totals exist — who voted
/// for what is never exposed by the API.
class _PollView extends StatelessWidget {
  const _PollView({required this.post, required this.poll});
  final ChannelPost post;
  final ChannelPoll poll;

  @override
  Widget build(BuildContext context) {
    final controller = context.read<ChannelsController>();
    final votes = [
      for (final v in jsonDecode(post.pollVotes) as List) (v as num).toInt(),
    ];
    final total = votes.fold(0, (sum, v) => sum + v);
    final showResults = post.myVote != null || poll.closed;
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 8, top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(poll.question, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          for (var i = 0; i < poll.options.length; i++)
            if (!showResults)
              OutlinedButton(
                onPressed: () =>
                    _guard(context, () => controller.vote(post, i)),
                child: Text(poll.options[i]),
              )
            else
              _PollResult(
                label: poll.options[i],
                share: total == 0 || i >= votes.length ? 0 : votes[i] / total,
                mine: post.myVote == i,
                // The vote may be changed until the poll closes.
                onTap: poll.closed
                    ? null
                    : () => _guard(context, () => controller.vote(post, i)),
              ),
          if (poll.closed)
            Text(
              context.l10n.channelPollClosed,
              style: Theme.of(context).textTheme.labelSmall,
            ),
        ],
      ),
    );
  }
}

class _PollResult extends StatelessWidget {
  const _PollResult({
    required this.label,
    required this.share,
    required this.mine,
    required this.onTap,
  });
  final String label;
  final double share;
  final bool mine;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label)),
              if (mine) const Icon(Icons.check_circle_rounded, size: 16),
              const SizedBox(width: 4),
              Text(
                NumberFormat.percentPattern(
                  context.l10n.localeName,
                ).format(share),
              ),
            ],
          ),
          LinearProgressIndicator(value: share),
        ],
      ),
    ),
  );
}

/// Compose bar for owner / admin / publisher: text, image (≤ 2 MiB) or poll.
class _ComposeBar extends StatefulWidget {
  const _ComposeBar({required this.channelId});
  final String channelId;

  @override
  State<_ComposeBar> createState() => _ComposeBarState();
}

class _ComposeBarState extends State<_ComposeBar> {
  final _text = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  /// [_busy] blocks a second tap while the first publish is in flight —
  /// each publish gets a fresh post id, so a double tap WOULD post twice.
  Future<void> _publish(Future<void> Function(ChannelsController) send) async {
    if (_busy) return;
    setState(() => _busy = true);
    await _guard(context, () => send(context.read<ChannelsController>()));
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _sendText() async {
    final body = _text.text.trim();
    if (body.isEmpty) return;
    await _publish((c) async {
      await c.publish(widget.channelId, kind: 'text', body: body);
      _text.clear();
    });
  }

  /// Mobile: the system photo picker (the document picker is the Files app
  /// on iOS). Every image is re-encoded to a JPEG within the channel limit:
  /// channel posts are PUBLIC, so the EXIF/GPS strip in [fitImageAsJpeg]
  /// matters even more here than in an E2E chat.
  Future<void> _sendImage() async {
    final media = AttachmentMedia.instance;
    final PickedMedia? picked;
    try {
      picked = AttachmentMedia.isMobile
          ? await media.pickGalleryImage()
          : (await media.pickImageFiles(multiple: false)).firstOrNull;
    } catch (error) {
      if (mounted) await _guard(context, () => Future.error(error));
      return;
    }
    if (picked == null || !mounted) return;
    final prepared = (await preparePhotos(
      context,
      [picked],
      maxBytes: channelImageMaxBytes,
    )).single;
    if (!mounted) return;
    final bytes = prepared.bytes;
    if (bytes == null) {
      await _guard(
        context,
        () => throw ChannelValidationException(
          prepared.decoded ? 'image_too_large' : 'unsupported_image_type',
        ),
      );
      return;
    }
    final caption = _text.text.trim();
    await _publish((c) async {
      await c.publish(
        widget.channelId,
        kind: 'image',
        body: caption,
        imageBytes: bytes,
        imageName: prepared.name,
      );
      _text.clear();
    });
  }

  Future<void> _sendPoll() async {
    // Plain variables instead of controllers: a controller would have to be
    // disposed while the dialog's exit animation still uses it.
    var question = '';
    var options = '';
    final l10n = context.l10n;
    final poll = await showDialog<ChannelPoll>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.channelNewPoll),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              onChanged: (v) => question = v,
              decoration: InputDecoration(labelText: l10n.channelPollQuestion),
            ),
            TextField(
              onChanged: (v) => options = v,
              minLines: 2,
              maxLines: 6,
              decoration: InputDecoration(
                labelText: l10n.channelPollOptions,
                helperText: l10n.channelPollOptionsHelper,
                helperMaxLines: 3,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () {
              final lines = [
                for (final line in options.split('\n'))
                  if (line.trim().isNotEmpty) line.trim(),
              ];
              if (question.trim().isEmpty || lines.length < 2) return;
              Navigator.of(
                dialogContext,
              ).pop(ChannelPoll(question: question.trim(), options: lines));
            },
            child: Text(l10n.channelPublish),
          ),
        ],
      ),
    );
    if (poll == null) return;
    await _publish(
      (c) => c.publish(widget.channelId, kind: 'poll', body: poll.encode()),
    );
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    key: const Key('channel-compose-bar'),
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.image_outlined),
            tooltip: context.l10n.channelPostImage,
            onPressed: _busy ? null : _sendImage,
          ),
          IconButton(
            icon: const Icon(Icons.poll_outlined),
            tooltip: context.l10n.channelPostPoll,
            onPressed: _busy ? null : _sendPoll,
          ),
          Expanded(
            child: TextField(
              controller: _text,
              minLines: 1,
              maxLines: 4,
              maxLength: 4096,
              decoration: InputDecoration(
                hintText: context.l10n.channelComposeHint,
                counterText: '',
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.send_rounded),
            tooltip: context.l10n.channelPublish,
            onPressed: _busy ? null : _sendText,
          ),
        ],
      ),
    ),
  );
}
