import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'router.dart';
import 'theme.dart';
import 'session_overlay.dart';

/// Root application widget.
///
/// Configures Material 3 theming (light + dark, follows system preference)
/// and GoRouter-based navigation. All top-level app concerns (e.g. future
/// Provider wrappers, localization) should be added here rather than in
/// main.dart, keeping the entry point minimal.
class CallTypeApp extends StatelessWidget {
  const CallTypeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Jay',
      // No `locale:` on purpose: Flutter resolves the UI language from the
      // OS / browser preference list against supportedLocales and falls back
      // to the first entry (English). There is no in-app language switch.
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      routerConfig: router,
      builder: (context, child) => SessionOverlay(child: child!),
      debugShowCheckedModeBanner: false,
    );
  }
}
