import 'package:flutter/material.dart';

/// A single message bubble in the chat view.
///
/// Aligns right for outgoing messages (mine) and left for incoming (theirs),
/// matching the universal messaging app convention. Max width is capped at
/// 75% of screen width to keep long messages readable and leave visual
/// breathing room on the opposite side.
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.text,
    required this.time,
    required this.isMine,
  });

  /// Message body text.
  final String text;

  /// Formatted timestamp to display in the bottom-right corner.
  final String time;

  /// Whether this message was sent by the local user.
  final bool isMine;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // Outgoing messages use the primary color to visually distinguish
    // them from incoming messages, which use a neutral surface variant.
    final backgroundColor =
        isMine ? colorScheme.primaryContainer : colorScheme.surfaceContainerHighest;
    final textColor =
        isMine ? colorScheme.onPrimaryContainer : colorScheme.onSurface;

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        // 75% max width prevents bubbles from spanning the full screen,
        // which would make it hard to tell sender from receiver visually.
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.75,
        ),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: backgroundColor,
            // Asymmetric border radius: the corner on the sender's side is
            // sharper to create a visual "tail" effect pointing toward the
            // message author.
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(isMine ? 16 : 4),
              bottomRight: Radius.circular(isMine ? 4 : 16),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                text,
                style: theme.textTheme.bodyMedium?.copyWith(color: textColor),
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
    );
  }
}
