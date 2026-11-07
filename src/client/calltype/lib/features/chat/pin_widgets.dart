import 'package:flutter/material.dart';

import '../../core/storage/database.dart';
import '../../l10n/l10n.dart';

/// The bar under the app bar of a chat with pinned messages (spec
/// 2026-11-08-chat-extras): the newest pin first. A tap jumps to the shown
/// message and moves the bar to the next older pin, like WhatsApp and
/// Telegram cycle through theirs; the list icon opens all of them.
class PinnedMessageBar extends StatefulWidget {
  const PinnedMessageBar({
    super.key,
    required this.pins,
    required this.previewOf,
    required this.onJump,
    required this.onShowAll,
  });

  /// Newest pin first.
  final List<Message> pins;
  final String Function(Message message) previewOf;
  final void Function(Message message) onJump;
  final VoidCallback onShowAll;

  @override
  State<PinnedMessageBar> createState() => _PinnedMessageBarState();
}

class _PinnedMessageBarState extends State<PinnedMessageBar> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final pins = widget.pins;
    if (pins.isEmpty) return const SizedBox.shrink();
    final index = _index % pins.length;
    final message = pins[index];
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final label = pins.length > 1
        ? '${l10n.chatPinnedLabel} ${index + 1}/${pins.length}'
        : l10n.chatPinnedLabel;
    return Material(
      key: const ValueKey('chat-pinned-bar'),
      color: theme.colorScheme.surfaceContainer,
      child: InkWell(
        onTap: () {
          widget.onJump(message);
          setState(() => _index = (index + 1) % pins.length);
        },
        child: Padding(
          padding: const EdgeInsetsDirectional.only(start: 16, end: 4),
          child: Row(
            children: [
              Icon(
                Icons.push_pin_outlined,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      Text(
                        widget.previewOf(message),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('chat-pinned-all'),
                icon: const Icon(Icons.list_rounded),
                tooltip: l10n.chatPinnedListTitle,
                onPressed: widget.onShowAll,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// All pinned messages of a chat: a tap jumps there, the pin icon unpins
/// ([onUnpin] null = not allowed here, e.g. business).
Future<void> showPinnedMessagesSheet(
  BuildContext context, {
  required List<Message> pins,
  required String Function(Message message) previewOf,
  required String Function(Message message) authorOf,
  required void Function(Message message) onJump,
  void Function(Message message)? onUnpin,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (sheetContext) {
    final l10n = sheetContext.l10n;
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                l10n.chatPinnedListTitle,
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            for (final message in pins)
              ListTile(
                leading: const Icon(Icons.push_pin_outlined),
                title: Text(
                  previewOf(message),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(authorOf(message)),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  onJump(message);
                },
                trailing: onUnpin == null
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close_rounded),
                        tooltip: l10n.chatMessageUnpin,
                        onPressed: () {
                          Navigator.of(sheetContext).pop();
                          onUnpin(message);
                        },
                      ),
              ),
          ],
        ),
      ),
    );
  },
);
