import 'package:calltype_core/messaging/agent_payload.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import 'link_text.dart';
import 'reaction_widgets.dart';
import 'reactions.dart';

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
    this.reactions = const [],
    this.myReaction,
    this.onReact,
    this.onReactionTap,
    this.onReactionLongPress,
    this.pickEmoji = showReactionEmojiPicker,
    this.outlineColor,
    this.quoteAccent,
    this.launchLink,
  });

  /// Opens a tapped link; null = the system browser / mail app (a test
  /// seam, spec 2026-11-10-clickable-links D8).
  final LinkLauncher? launchLink;

  /// A 1.5 px outline in this color (a group member's color, spec
  /// 2026-11-09-participant-colors D1). Null = no outline, as before.
  final Color? outlineColor;

  /// Accent bar and author color of the quote block (D8). Null = the theme's
  /// primary color, as before.
  final Color? quoteAccent;

  /// Reaction chips drawn under the bubble.
  final List<ReactionSummary> reactions;

  /// The local user's current reaction (highlighted in the quick bar).
  final String? myReaction;

  /// A pick from the quick bar or the full picker. Null = no reacting here
  /// (tombstone, pending send, business conversation): no quick bar.
  final void Function(String emoji)? onReact;

  /// Tap / long-press on a chip (remove own, show who reacted).
  final void Function(ReactionSummary chip)? onReactionTap;
  final void Function(ReactionSummary chip)? onReactionLongPress;

  /// Opens the full picker behind "+" (a test seam).
  final EmojiPickerLauncher pickEmoji;

  /// "+" in the quick bar: the full picker, then the same path as a quick
  /// pick. [context] must outlive the sheet/menu that was just closed.
  Future<void> _pickMore(BuildContext context) async {
    final emoji = await pickEmoji(context);
    if (emoji != null) onReact?.call(emoji);
  }

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
      // Scrollable: the quick bar plus five actions is taller than the
      // sheet on a small or landscape screen.
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (onReact != null) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: ReactionQuickBar(
                      selected: myReaction,
                      onPick: (emoji) {
                        Navigator.of(sheetContext).pop();
                        onReact!(emoji);
                      },
                      onMore: () {
                        Navigator.of(sheetContext).pop();
                        _pickMore(context);
                      },
                    ),
                  ),
                ),
                if (actions.isNotEmpty) const Divider(height: 1),
              ],
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
    // Own bubble: the text color the theme pairs with primaryContainer, the
    // underline marks the link; others: primary (spec D12).
    final linkColor = isMine ? textColor : colorScheme.primary;

    // WHY a visible button and not just a gesture: in a browser the right
    // mouse button belongs to the browser's own context menu and nobody
    // discovers "hold the left button". So wherever a mouse is likely (web,
    // desktop) every message gets a three-dots menu; long-press stays as the
    // familiar shortcut on touch screens.
    final hasMenu = actions.isNotEmpty || onReact != null;
    final showMenuButton =
        hasMenu &&
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
              // The quick bar on top of the menu: the desktop / web way to
              // react (right click belongs to the browser, see above).
              if (onReact != null)
                _ReactionMenuEntry(
                  selected: myReaction,
                  onPick: onReact!,
                  onMore: () => _pickMore(context),
                ),
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
                onLongPress: hasMenu ? () => _showSheet(context) : null,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: isMine
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    Container(
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
                        border: outlineColor == null
                            ? null
                            : Border.all(color: outlineColor!, width: 1.5),
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
                              accent: quoteAccent ?? colorScheme.primary,
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
                                  child: LinkifiedText(
                                    caption!,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: textColor,
                                    ),
                                    linkColor: linkColor,
                                    launcher: launchLink,
                                    onLongPressOutsideLink: hasMenu
                                        ? () => _showSheet(context)
                                        : null,
                                  ),
                                ),
                              ],
                            )
                          else
                            content ??
                                LinkifiedText(
                                  text,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: textColor,
                                  ),
                                  linkColor: linkColor,
                                  launcher: launchLink,
                                  onLongPressOutsideLink: hasMenu
                                      ? () => _showSheet(context)
                                      : null,
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
                    if (reactions.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(
                          left: 12,
                          right: 12,
                          bottom: 4,
                        ),
                        child: ReactionChips(
                          reactions: reactions,
                          onTap: onReactionTap,
                          onLongPress: onReactionLongPress,
                        ),
                      ),
                  ],
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

/// The quick bar as the first entry of the three-dots menu. Not selectable
/// itself; each emoji closes the menu and reacts.
class _ReactionMenuEntry extends PopupMenuEntry<void> {
  const _ReactionMenuEntry({
    required this.selected,
    required this.onPick,
    required this.onMore,
  });

  final String? selected;
  final void Function(String emoji) onPick;
  final VoidCallback onMore;

  @override
  double get height => 52;

  @override
  bool represents(void value) => false;

  @override
  State<_ReactionMenuEntry> createState() => _ReactionMenuEntryState();
}

class _ReactionMenuEntryState extends State<_ReactionMenuEntry> {
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    // The menu is at most 280 wide; the bar shrinks instead of overflowing.
    child: FittedBox(
      fit: BoxFit.scaleDown,
      child: ReactionQuickBar(
        selected: widget.selected,
        onPick: (emoji) {
          Navigator.of(context).pop();
          widget.onPick(emoji);
        },
        onMore: () {
          Navigator.of(context).pop();
          widget.onMore();
        },
      ),
    ),
  );
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
