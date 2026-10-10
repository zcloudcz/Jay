import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';

/// A single message bubble in the chat view.
///
/// Aligns to the END side for outgoing messages (mine) and to the START side
/// for incoming (theirs): right/left in LTR languages and mirrored in RTL
/// ones (Arabic), matching the universal messaging app convention. Max width is capped at
/// 75% of screen width to keep long messages readable and leave visual
/// breathing room on the opposite side.
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.text,
    required this.time,
    required this.isMine,
    this.onCopy,
  });

  /// Message body text.
  final String text;

  /// Formatted timestamp to display in the bottom-right corner.
  final String time;

  /// Whether this message was sent by the local user.
  final bool isMine;

  /// Copies this message. Null hides the message menu entirely.
  final VoidCallback? onCopy;

  /// Touch fallback: the same single action as the three-dots menu, as a
  /// bottom sheet (a popup has no visible anchor after a long-press).
  void _showSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListTile(
          leading: const Icon(Icons.copy_rounded),
          title: Text(sheetContext.l10n.chatMessageCopy),
          // onCopy runs inside the tap handler itself, not after the sheet's
          // future completes: browsers (Safari above all) only allow
          // clipboard writes directly within a user gesture.
          onTap: () {
            Navigator.of(sheetContext).pop();
            onCopy?.call();
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // Outgoing messages use the primary color to visually distinguish
    // them from incoming messages, which use a neutral surface variant.
    final backgroundColor = isMine
        ? colorScheme.primaryContainer
        : colorScheme.surfaceContainerHighest;
    final textColor = isMine
        ? colorScheme.onPrimaryContainer
        : colorScheme.onSurface;

    // WHY a visible button and not just a gesture: in a browser the right
    // mouse button belongs to the browser's own context menu and nobody
    // discovers "hold the left button". So wherever a mouse is likely (web,
    // desktop) every message gets a three-dots menu; long-press stays as the
    // familiar shortcut on touch screens.
    final showMenuButton =
        onCopy != null &&
        (kIsWeb ||
            const {
              TargetPlatform.windows,
              TargetPlatform.macOS,
              TargetPlatform.linux,
            }.contains(defaultTargetPlatform));
    final menu = !showMenuButton
        ? null
        : PopupMenuButton<void>(
            icon: Icon(
              Icons.more_vert,
              size: 18,
              color: colorScheme.onSurfaceVariant,
            ),
            padding: EdgeInsets.zero,
            itemBuilder: (_) => [
              PopupMenuItem(
                onTap: onCopy,
                child: Row(
                  children: [
                    const Icon(Icons.copy_rounded, size: 20),
                    const SizedBox(width: 12),
                    Text(context.l10n.chatMessageCopy),
                  ],
                ),
              ),
            ],
          );

    return Align(
      alignment: isMine
          ? AlignmentDirectional.centerEnd
          : AlignmentDirectional.centerStart,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // The menu sits on the inner side of the bubble (towards the
          // middle of the screen) so it never pushes the bubble off its edge.
          if (menu != null && isMine) menu,
          Flexible(
            child: ConstrainedBox(
              // 75% max width prevents bubbles from spanning the full screen,
              // which would make it hard to tell sender from receiver visually.
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width * 0.75,
              ),
              child: GestureDetector(
                onLongPress: onCopy == null ? null : () => _showSheet(context),
                child: Container(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: backgroundColor,
                    // Asymmetric border radius: the corner on the sender's side is
                    // sharper to create a visual "tail" effect pointing toward the
                    // message author. Directional so the tail follows the bubble
                    // when the layout is mirrored for RTL.
                    borderRadius: BorderRadiusDirectional.only(
                      topStart: const Radius.circular(16),
                      topEnd: const Radius.circular(16),
                      bottomStart: Radius.circular(isMine ? 16 : 4),
                      bottomEnd: Radius.circular(isMine ? 4 : 16),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        text,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: textColor,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        time,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: textColor.withAlpha(150),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (menu != null && !isMine) menu,
        ],
      ),
    );
  }
}
