import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';

/// Small badge shown on a business conversation's row in the chat list
/// (plan §5 E05 deliverable 2 — "Banner also in the conversation list row").
class BusinessBadge extends StatelessWidget {
  const BusinessBadge({super.key, required this.organizationName});
  final String organizationName;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: context.l10n.businessBannerText(organizationName),
    child: Icon(
      Icons.verified_user_rounded,
      size: 16,
      color: Theme.of(context).colorScheme.tertiary,
    ),
  );
}

/// Permanent, non-dismissable banner shown at the top of every business
/// conversation (KB1 legal invariant — the client offers no way to hide or
/// remove it). Tapping it opens the transparency info sheet.
class BusinessBanner extends StatelessWidget {
  const BusinessBanner({super.key, required this.organizationName});
  final String organizationName;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return MaterialBanner(
      leading: const Icon(Icons.verified_user_rounded),
      content: Text(l10n.businessBannerText(organizationName)),
      // Intentionally no dismiss/close action here — KB1 requires this
      // banner to be permanent for every business conversation.
      actions: [
        TextButton(
          onPressed: () => showBusinessInfoSheet(context, organizationName),
          child: Text(l10n.businessInfoTitle),
        ),
      ],
    );
  }
}

/// Member-list row for the organization's archive (audit) member. Never
/// offers a remove action — the auditor is immutable from the client, by
/// design (server enforces it too, but the UI must not even suggest it).
class AuditorMemberTile extends StatelessWidget {
  const AuditorMemberTile({super.key, required this.organizationName});
  final String organizationName;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.shield_rounded),
    title: Text(context.l10n.businessAuditorTile(organizationName)),
    // No `trailing` remove/delete control — see class doc.
  );
}

/// Plain-language explanation of what business mode archives, shown from
/// the banner and from Organization settings (K06 honesty requirement).
void showBusinessInfoSheet(BuildContext context, String organizationName) {
  final l10n = context.l10n;
  showModalBottomSheet<void>(
    context: context,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.businessInfoTitle,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            Text(l10n.businessInfoBody(organizationName)),
          ],
        ),
      ),
    ),
  );
}
