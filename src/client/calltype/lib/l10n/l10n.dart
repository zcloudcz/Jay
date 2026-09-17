import 'package:flutter/widgets.dart';

import 'app_localizations.dart';

export 'app_localizations.dart';

/// `context.l10n.someKey` instead of `AppLocalizations.of(context).someKey`.
///
/// Deliberately the ONLY way to reach translations: there is no global
/// singleton, so code without a BuildContext (controllers, services) has to
/// return an error code / enum and let the widget map it to text. That keeps
/// the language tied to the widget tree's locale (OS / browser setting).
extension L10nContext on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}
