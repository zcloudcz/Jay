import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../app.dart';
import 'format.dart';

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(errorMessage(l, error), style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onRetry, child: Text(l.retry)),
          ],
        ),
      ),
    );
  }
}

class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.label, this.color, this.onColor});

  final String label;
  final Color? color;
  final Color? onColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color ?? scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: onColor ?? scheme.onSurfaceVariant),
      ),
    );
  }
}

class ChannelStatusChip extends StatelessWidget {
  const ChannelStatusChip({super.key, required this.channel});

  final ChannelSummary channel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = channelStatusLabel(context.l10n, channel);
    if (channel.deleted) {
      return StatusChip(label: label, color: scheme.errorContainer, onColor: scheme.onErrorContainer);
    }
    if (channel.isSuspended) {
      return StatusChip(label: label, color: scheme.tertiaryContainer, onColor: scheme.onTertiaryContainer);
    }
    return StatusChip(label: label);
  }
}

/// Category counts as chips; illegal first and in the error colour because
/// it is the one that may need a report to the authorities (DSA Art. 18).
class CategoryChips extends StatelessWidget {
  const CategoryChips({super.key, required this.categories});

  final Map<String, int> categories;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    const order = ['illegal', 'terms', 'spam'];
    final keys = [
      ...order.where(categories.containsKey),
      ...categories.keys.where((k) => !order.contains(k)),
    ].where((k) => (categories[k] ?? 0) > 0);
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final k in keys)
          StatusChip(
            label: '${categoryLabel(l, k)} ${categories[k]}',
            color: k == 'illegal' ? scheme.errorContainer : null,
            onColor: k == 'illegal' ? scheme.onErrorContainer : null,
          ),
      ],
    );
  }
}

/// Text of a post for the operator; polls are stored as JSON
/// `{question, options, closesAt?}`.
String postText(BuildContext context, PostSummary p) {
  if (p.kind == 'poll') {
    try {
      final j = jsonDecode(p.body) as Map;
      final opts = (j['options'] as List).map((o) => '  - $o').join('\n');
      return '${context.l10n.pollLabel}: ${j['question']}\n$opts';
    } catch (_) {
      return p.body;
    }
  }
  return p.body;
}

/// One post card: kind, BOT label, deleted state, text, image (blurred).
class PostCard extends StatelessWidget {
  const PostCard({
    super.key,
    required this.channelId,
    required this.post,
    this.highlighted = false,
    this.maxLines,
    this.loadImage = true,
  });

  final String channelId;
  final PostSummary post;
  final bool highlighted;
  final int? maxLines;

  /// The queue shows only a placeholder: no image bytes are fetched until the
  /// operator opens the case and clicks.
  final bool loadImage;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final text = postText(context, post);
    return Card(
      key: highlighted ? const Key('reported-post') : null,
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: highlighted ? scheme.secondaryContainer : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(formatDateTime(context, post.createdAt), style: Theme.of(context).textTheme.labelSmall),
                if (post.byBot) StatusChip(label: l.botLabel, color: scheme.tertiaryContainer, onColor: scheme.onTertiaryContainer),
                if (post.deleted) StatusChip(label: l.postDeleted, color: scheme.errorContainer, onColor: scheme.onErrorContainer),
              ],
            ),
            if (text.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(text, maxLines: maxLines, overflow: maxLines == null ? null : TextOverflow.ellipsis),
            ],
            if (post.attachmentName != null) ...[
              const SizedBox(height: 8),
              loadImage
                  ? BlurredAttachment(channelId: channelId, name: post.attachmentName!)
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [const Icon(Icons.image_outlined, size: 18), const SizedBox(width: 4), Text(l.imageHidden)],
                    ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Image hidden behind a strong blur until the operator clicks it.
///
/// WHY: moderator wellbeing (research section 3, TSPA): reported images are
/// disproportionately disturbing, so seeing one must be a deliberate act. The
/// bytes come through the API client because the admin route needs the
/// Bearer token, which an <img src> cannot send.
class BlurredAttachment extends StatefulWidget {
  const BlurredAttachment({super.key, required this.channelId, required this.name});

  final String channelId;
  final String name;

  @override
  State<BlurredAttachment> createState() => _BlurredAttachmentState();
}

class _BlurredAttachmentState extends State<BlurredAttachment> {
  Future<Uint8List>? _bytes;
  bool _revealed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bytes ??= AdminScope.of(context).api.attachment(widget.channelId, widget.name);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return FutureBuilder<Uint8List>(
      future: _bytes,
      builder: (context, snap) {
        if (snap.hasError) return Text(l.imageError);
        if (!snap.hasData) {
          return const SizedBox(height: 160, width: 240, child: Center(child: CircularProgressIndicator()));
        }
        final image = Image.memory(
          snap.data!,
          height: 240,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => Text(l.imageError),
        );
        if (_revealed) return KeyedSubtree(key: const Key('image-revealed'), child: image);
        return Semantics(
          button: true,
          label: l.imageReveal,
          child: InkWell(
            key: const Key('image-blurred'),
            onTap: () => setState(() => _revealed = true),
            child: ClipRect(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 28, sigmaY: 28, tileMode: TileMode.decal),
                    child: image,
                  ),
                  Container(
                    padding: const EdgeInsets.all(8),
                    color: Colors.black54,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.visibility_off, color: Colors.white),
                        const SizedBox(width: 8),
                        Text(l.imageReveal, style: const TextStyle(color: Colors.white)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
