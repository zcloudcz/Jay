import 'package:flutter/material.dart';

/// Shown on EVERY channel screen. Everything else in Jay is end-to-end
/// encrypted, so a user would reasonably assume channels are too. They are
/// not: the server stores channel posts as readable text. The app must never
/// pretend otherwise (project rule: be honest about crypto limits).
const channelPublicNotice =
    'Channel posts are public and NOT end-to-end encrypted.';

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
              channelPublicNotice,
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
