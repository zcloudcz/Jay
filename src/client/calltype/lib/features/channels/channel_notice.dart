import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';

/// Shown on EVERY channel screen. Everything else in Jay is end-to-end
/// encrypted, so a user would reasonably assume channels are too. They are
/// not: the server stores channel posts as readable text. The app must never
/// pretend otherwise (project rule: be honest about crypto limits). The text
/// is the `channelPublicNotice` message in lib/l10n.
class ChannelPublicNotice extends StatelessWidget {
  const ChannelPublicNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.tertiaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(
            Icons.public_rounded,
            size: 18,
            color: scheme.onTertiaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              context.l10n.channelPublicNotice,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onTertiaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
