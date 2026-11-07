import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import 'reactions.dart';

/// Opens the full emoji picker and returns the picked emoji (null when the
/// user closed it). A test seam: widget tests pass their own function.
typedef EmojiPickerLauncher = Future<String?> Function(BuildContext context);

/// The full picker as a bottom sheet (`emoji_picker_flutter`: Android, iOS,
/// web, macOS, Windows, Linux). Only emojis a receiver accepts are returned.
Future<String?> showReactionEmojiPicker(BuildContext context) {
  final colors = Theme.of(context).colorScheme;
  final locale = Localizations.localeOf(context);
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: SizedBox(
        height: 360,
        child: EmojiPicker(
          onEmojiSelected: (_, emoji) {
            if (isValidReactionEmoji(emoji.emoji)) {
              Navigator.of(sheetContext).pop(emoji.emoji);
            }
          },
          config: Config(
            locale: locale,
            emojiViewConfig: EmojiViewConfig(
              backgroundColor: colors.surface,
              columns: 8,
            ),
            categoryViewConfig: CategoryViewConfig(
              backgroundColor: colors.surface,
              indicatorColor: colors.primary,
              iconColorSelected: colors.primary,
            ),
            bottomActionBarConfig: const BottomActionBarConfig(
              // A reaction is one emoji: nothing to delete, and the search
              // bar would need its own text field state.
              enabled: false,
            ),
          ),
        ),
      ),
    ),
  );
}

/// The quick bar: 👍 ❤️ 😂 😮 😢 🙏 and "+" for the full picker. [selected]
/// (the user's current reaction) is highlighted; picking it again removes it.
class ReactionQuickBar extends StatelessWidget {
  const ReactionQuickBar({
    super.key,
    required this.selected,
    required this.onPick,
    required this.onMore,
  });

  final String? selected;
  final void Function(String emoji) onPick;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final emoji in quickReactions)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: InkWell(
              key: ValueKey('quick-reaction:$emoji'),
              customBorder: const CircleBorder(),
              onTap: () => onPick(emoji),
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: emoji == selected ? colors.primaryContainer : null,
                ),
                child: Text(emoji, style: const TextStyle(fontSize: 24)),
              ),
            ),
          ),
        IconButton(
          key: const ValueKey('quick-reaction:more'),
          icon: const Icon(Icons.add_reaction_outlined),
          tooltip: context.l10n.chatReactionMore,
          onPressed: onMore,
        ),
      ],
    );
  }
}

/// The chips under a bubble: one per emoji with its count; the user's own
/// one is outlined in the primary color.
class ReactionChips extends StatelessWidget {
  const ReactionChips({
    super.key,
    required this.reactions,
    this.onTap,
    this.onLongPress,
  });

  final List<ReactionSummary> reactions;
  final void Function(ReactionSummary chip)? onTap;
  final void Function(ReactionSummary chip)? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final chip in reactions)
          Material(
            key: ValueKey('reaction-chip:${chip.emoji}'),
            color: chip.mine
                ? colors.primaryContainer
                : colors.surfaceContainerHigh,
            shape: StadiumBorder(
              side: BorderSide(
                color: chip.mine ? colors.primary : colors.outlineVariant,
              ),
            ),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: onTap == null ? null : () => onTap!(chip),
              onLongPress: onLongPress == null
                  ? null
                  : () => onLongPress!(chip),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: Text(
                  chip.count > 1 ? '${chip.emoji} ${chip.count}' : chip.emoji,
                  style: theme.textTheme.labelMedium,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// "Who reacted": every reactor with their emoji. Tapping the user's own
/// row removes it (when [onRemoveMine] is given).
Future<void> showReactorsSheet(
  BuildContext context, {
  required List<ReactionSummary> reactions,
  required String Function(String identityId) nameOf,
  required String myId,
  VoidCallback? onRemoveMine,
}) {
  final l10n = context.l10n;
  final me = myId.toLowerCase();
  final rows = [
    for (final chip in reactions)
      for (final id in chip.reactorIds) (emoji: chip.emoji, id: id),
  ];
  return showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              l10n.chatReactionsTitle,
              style: Theme.of(sheetContext).textTheme.titleMedium,
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final row in rows)
                  ListTile(
                    leading: Text(
                      row.emoji,
                      style: const TextStyle(fontSize: 24),
                    ),
                    title: Text(nameOf(row.id)),
                    subtitle: row.id.toLowerCase() == me && onRemoveMine != null
                        ? Text(l10n.chatReactionTapToRemove)
                        : null,
                    onTap: row.id.toLowerCase() == me && onRemoveMine != null
                        ? () {
                            Navigator.of(sheetContext).pop();
                            onRemoveMine();
                          }
                        : null,
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
