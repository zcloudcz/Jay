import 'package:calltype/l10n/l10n.dart';
import 'package:flutter/material.dart';

/// English messages for assertions, e.g. `find.text(l10nEn.botNotice)` —
/// so tests do not duplicate long user-facing sentences.
final AppLocalizations l10nEn = lookupAppLocalizations(const Locale('en'));

/// The ONE place where widget tests get a localized MaterialApp. Every screen
/// reads `context.l10n`, which throws without the delegates — so tests wrap
/// the widget here instead of repeating delegates/supportedLocales.
///
/// [locale] defaults to English so existing `find.text('…')` assertions keep
/// working; pass another one to exercise a translation or RTL. An unsupported
/// locale resolves to English, exactly like in the real app.
Widget localizedApp({
  Widget? home,
  RouterConfig<Object>? router,
  Locale locale = const Locale('en'),
}) {
  assert((home == null) != (router == null), 'pass either home or router');
  return router != null
      ? MaterialApp.router(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        )
      : MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: home,
        );
}
