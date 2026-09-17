import 'package:flutter/material.dart';

/// Shown wherever the user decides to trust or talk to a bot (add-contact
/// preview, first chat open). The chat is still end-to-end encrypted, but
/// the "other end" is a program run by someone else — and `isBot` is only
// The bot warning itself is the `botNotice` message in lib/l10n: it is shown
// wherever the user decides to trust or talk to a bot (add-contact preview,
// first chat open). The chat is still end-to-end encrypted, but the "other
// end" is a program run by someone else — and `isBot` is only the device's
// own declaration, not a verified badge. The text says both honestly.

/// Small "BOT" pill next to a contact's name. Uses the brand orange
/// (tertiary) so it cannot be mistaken for the primary-coloured "verified"
/// check mark.
class BotBadge extends StatelessWidget {
  const BotBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      // Directional: the badge follows the name, which starts on the right
      // in RTL languages.
      margin: const EdgeInsetsDirectional.only(start: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.tertiary,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        // Not translated on purpose: a fixed, recognisable label.
        'BOT',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: scheme.onTertiary,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// A name with an optional [BotBadge]; the name ellipsizes, the badge never
/// gets pushed out of view.
class NameWithBotBadge extends StatelessWidget {
  const NameWithBotBadge({super.key, required this.name, required this.isBot});

  final String name;
  final bool isBot;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Flexible(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis)),
      if (isBot) const BotBadge(),
    ],
  );
}
