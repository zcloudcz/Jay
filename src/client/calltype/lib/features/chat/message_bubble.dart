import 'package:calltype_core/messaging/agent_payload.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';

/// One entry of the message menu. The same list feeds the three-dots popup
/// (web/desktop) and the long-press bottom sheet (touch).
class MessageAction {
  const MessageAction({
    required this.icon,
    required this.label,
    required this.onSelected,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onSelected;

  /// Drawn in the error color (delete).
  final bool destructive;
}

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
    this.actions = const [],
    this.content,
    this.caption,
    this.quoteAuthor,
    this.quoteText,
    this.forwarded = false,
    this.deleted = false,
    this.edited = false,
    this.buttons = const [],
    this.onButton,
  });

  /// Shows the small "edited" label next to the time.
  final bool edited;

  /// Bot buttons under the text. The CALLER decides whether they may show
  /// (only for a received message of a bot); this widget just draws them.
  final List<MessageButton> buttons;

  /// Tap on one of [buttons]; null draws them disabled.
  final void Function(MessageButton button)? onButton;

  /// Message body text (ignored when [content] or [deleted] is set).
  final String text;

  /// Replaces the text, e.g. the download button of a file attachment.
  final Widget? content;

  /// Text under [content] (a photo caption); ignored without [content].
  final String? caption;

  /// Quoted message shown above the content (reply).
  final String? quoteAuthor;
  final String? quoteText;

  /// Shows the small "Forwarded" line.
  final bool forwarded;

  /// "Deleted for everyone" tombstone: muted placeholder, no quote/forwarded.
  final bool deleted;

  /// Formatted timestamp to display in the bottom-right corner.
  final String time;

  /// Whether this message was sent by the local user.
  final bool isMine;

  /// Menu entries. Empty hides the message menu and the long-press entirely.
  final List<MessageAction> actions;

  /// Touch fallback: the same actions as the three-dots menu, as a bottom
  /// sheet (a popup has no visible anchor after a long-press).
  void _showSheet(BuildContext context) {
    final errorColor = Theme.of(context).colorScheme.error;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final action in actions)
              ListTile(
                leading: Icon(
                  action.icon,
                  color: action.destructive ? errorColor : null,
                ),
                title: Text(
                  action.label,
                  style: action.destructive
                      ? TextStyle(color: errorColor)
                      : null,
                ),
                // onSelected runs inside the tap handler itself, not after
                // the sheet's future completes: browsers (Safari above all)
                // only allow clipboard writes directly within a user gesture.
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  action.onSelected();
                },
              ),
          ],
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
        actions.isNotEmpty &&
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
              for (final action in actions)
                PopupMenuItem(
                  // PopupMenuItem.onTap runs synchronously in the tap
                  // handler, which keeps the clipboard-gesture rule.
                  onTap: action.onSelected,
                  child: Row(
                    children: [
                      Icon(
                        action.icon,
                        size: 20,
                        color: action.destructive ? colorScheme.error : null,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        action.label,
                        style: action.destructive
                            ? TextStyle(color: colorScheme.error)
                            : null,
                      ),
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
                onLongPress: actions.isEmpty ? null : () => _showSheet(context),
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
                      if (forwarded && !deleted)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.forward_rounded,
                                size: 14,
                                color: textColor.withAlpha(150),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                context.l10n.chatMessageForwarded,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: textColor.withAlpha(150),
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (quoteText != null && !deleted)
                        _Quote(
                          author: quoteAuthor,
                          text: quoteText!,
                          textColor: textColor,
                          accent: colorScheme.primary,
                        ),
                      if (deleted)
                        Text(
                          context.l10n.chatMessageDeleted,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: textColor.withAlpha(150),
                            fontStyle: FontStyle.italic,
                          ),
                        )
                      else if (content != null && caption != null)
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            content!,
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                caption!,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: textColor,
                                ),
                              ),
                            ),
                          ],
                        )
                      else
                        content ??
                            Text(
                              text,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: textColor,
                              ),
                            ),
                      if (buttons.isNotEmpty && !deleted)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final button in buttons)
                                OutlinedButton(
                                  onPressed: onButton == null
                                      ? null
                                      : () => onButton!(button),
                                  child: Text(button.label),
                                ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (edited && !deleted) ...[
                            Text(
                              context.l10n.chatMessageEdited,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: textColor.withAlpha(150),
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                            const SizedBox(width: 6),
                          ],
                          Text(
                            time,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: textColor.withAlpha(150),
                            ),
                          ),
                        ],
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

/// Quoted message block: inset, with an accent border on the start side
/// (directional so it flips in RTL).
class _Quote extends StatelessWidget {
  const _Quote({
    required this.author,
    required this.text,
    required this.textColor,
    required this.accent,
  });

  final String? author;
  final String text;
  final Color textColor;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsetsDirectional.only(start: 8, top: 2, bottom: 2),
      decoration: BoxDecoration(
        color: textColor.withAlpha(20),
        border: BorderDirectional(start: BorderSide(color: accent, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (author != null)
            Text(
              author!,
              style: theme.textTheme.labelSmall?.copyWith(
                color: accent,
                fontWeight: FontWeight.bold,
              ),
            ),
          Text(
            text,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: textColor),
          ),
        ],
      ),
    );
  }
}
