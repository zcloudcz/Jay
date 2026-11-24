import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/l10n.dart';

/// The legal and support pages on the web (spec 2026-11-14-go-live D14 / W1-W4).
/// Static files of the app's Static Web App; `test/web/legal_pages_test.dart`
/// checks that every page linked from here exists in `web/legal/`.
enum LegalPage {
  privacy('privacy'),
  terms('terms'),
  deleteAccount('delete-account'),
  support('support');

  const LegalPage(this.slug);
  final String slug;
}

const legalBaseUrl = 'https://jay.zcloud.cz/legal';

/// Czech page for a Czech UI, English for every other language (the pages
/// exist in these two languages only).
String legalUrl(LegalPage page, String languageCode) =>
    '$legalBaseUrl/${page.slug}-${languageCode == 'cs' ? 'cs' : 'en'}.html';

/// Opens a web address outside the app. A variable so widget tests can
/// record the call instead of reaching the platform plugin.
@visibleForTesting
Future<bool> Function(Uri uri) legalUrlLauncher = (uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// Opens [page] in the browser; a failure shows the address so the user can
/// still get there.
Future<void> openLegalPage(BuildContext context, LegalPage page) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  final url = legalUrl(page, l10n.localeName);
  var opened = false;
  try {
    opened = await legalUrlLauncher(Uri.parse(url));
  } catch (_) {
    // No browser / plugin missing: fall through to the message.
  }
  if (!opened) {
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.channelLinkOpenFailed(url))),
    );
  }
}

/// "By continuing you agree to the Terms of use and the Privacy policy."
/// with both links (spec A6): shown on onboarding and on registration.
class LegalConsentLine extends StatelessWidget {
  const LegalConsentLine({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Column(
      key: const ValueKey('legal-consent'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          l10n.legalConsent,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Wrap(
          alignment: WrapAlignment.center,
          children: [
            TextButton(
              key: const ValueKey('legal-consent-terms'),
              onPressed: () => openLegalPage(context, LegalPage.terms),
              child: Text(l10n.legalTerms),
            ),
            TextButton(
              key: const ValueKey('legal-consent-privacy'),
              onPressed: () => openLegalPage(context, LegalPage.privacy),
              child: Text(l10n.legalPrivacyPolicy),
            ),
          ],
        ),
      ],
    );
  }
}

/// Settings > About and Settings > Privacy: one row per page.
class LegalPageTile extends StatelessWidget {
  const LegalPageTile({super.key, required this.page});

  final LegalPage page;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (icon, title) = switch (page) {
      LegalPage.privacy => (
        Icons.privacy_tip_outlined,
        l10n.legalPrivacyPolicy,
      ),
      LegalPage.terms => (Icons.description_outlined, l10n.legalTerms),
      LegalPage.deleteAccount => (
        Icons.delete_forever_outlined,
        l10n.deleteAccountTitle,
      ),
      LegalPage.support => (Icons.help_outline_rounded, l10n.legalSupport),
    };
    return ListTile(
      key: ValueKey('legal-${page.slug}'),
      leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
      title: Text(title),
      trailing: const Icon(Icons.open_in_new_rounded, size: 18),
      onTap: () => openLegalPage(context, page),
    );
  }
}
