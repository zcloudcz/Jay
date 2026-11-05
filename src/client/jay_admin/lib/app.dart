import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';

import 'api/admin_api.dart';
import 'l10n/app_localizations.dart';
import 'platform/browser.dart';
import 'screens/audit_screen.dart';
import 'screens/case_screen.dart';
import 'screens/channels_screen.dart';
import 'screens/login_screen.dart';
import 'screens/overview_screen.dart';
import 'screens/queue_screen.dart';
import 'screens/shell.dart';
import 'session.dart';

/// Dependencies every screen needs. An InheritedWidget instead of a state
/// management package: there is one API, one session and no shared mutable
/// state between screens (each loads what it shows).
class AdminScope extends InheritedWidget {
  const AdminScope({
    super.key,
    required this.api,
    required this.session,
    required this.browser,
    required super.child,
  });

  final AdminApi api;
  final SessionController session;
  final BrowserActions browser;

  static AdminScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AdminScope>()!;

  @override
  bool updateShouldNotify(AdminScope old) =>
      api != old.api || session != old.session || browser != old.browser;
}

/// Same look as the Jay app: Material 3 seeded from the brand petrol with the
/// brand orange as tertiary (src/client/calltype/lib/app/theme.dart). Denser
/// visual density because this is a desk tool full of lists.
class AdminTheme {
  AdminTheme._();

  static const seed = Color(0xFF003840);
  static const accent = Color(0xFFFF8545);

  static ThemeData _build(Brightness b) => ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: seed, tertiary: accent, brightness: b),
    useMaterial3: true,
    visualDensity: VisualDensity.compact,
  );

  static final light = _build(Brightness.light);
  static final dark = _build(Brightness.dark);
}

/// Only internal absolute paths may be a post-login target.
String safeReturnPath(String? from) {
  if (from == null || !from.startsWith('/') || from.startsWith('//')) return '/overview';
  if (from.startsWith('/login')) return '/overview';
  return from;
}

GoRouter buildRouter(SessionController session, {String initialLocation = '/overview'}) {
  return GoRouter(
    initialLocation: initialLocation,
    refreshListenable: session,
    redirect: (context, state) {
      final atLogin = state.matchedLocation == '/login';
      if (!session.isLoggedIn) {
        if (atLogin) return null;
        // Keep the whole location (path + filters) so re-login after expiry
        // lands exactly where the operator was.
        return Uri(path: '/login', queryParameters: {'from': state.uri.toString()}).toString();
      }
      if (atLogin) return safeReturnPath(state.uri.queryParameters['from']);
      if (state.matchedLocation == '/') return '/overview';
      return null;
    },
    routes: [
      GoRoute(path: '/', builder: (_, _) => const SizedBox.shrink()),
      GoRoute(
        path: '/login',
        builder: (_, state) => const LoginScreen(),
      ),
      ShellRoute(
        builder: (context, state, child) => AdminShell(location: state.uri, child: child),
        routes: [
          GoRoute(path: '/overview', builder: (_, _) => const OverviewScreen()),
          GoRoute(
            path: '/queue',
            builder: (_, state) {
              final q = state.uri.queryParameters;
              return QueueScreen(
                key: ValueKey(state.uri.toString()),
                status: const {'open', 'resolved', 'all'}.contains(q['status']) ? q['status']! : 'open',
                category: q['category'],
                subjectType: q['subjectType'],
              );
            },
          ),
          GoRoute(
            path: '/case/:channelId',
            builder: (_, state) => CaseScreen(
              key: ValueKey(state.uri.toString()),
              channelId: state.pathParameters['channelId']!,
              postId: state.uri.queryParameters['postId'],
              fromQueue: state.uri.queryParameters['from'] == 'queue',
            ),
          ),
          GoRoute(
            path: '/channels',
            builder: (_, state) => ChannelsScreen(initialQuery: state.uri.queryParameters['q'] ?? ''),
          ),
          GoRoute(path: '/audit', builder: (_, _) => const AuditScreen()),
        ],
      ),
    ],
  );
}

class AdminApp extends StatefulWidget {
  const AdminApp({
    super.key,
    required this.api,
    required this.session,
    this.browser = const RealBrowserActions(),
    this.configError,
    this.initialLocation = '/overview',
    this.locale,
  });

  final AdminApi api;
  final SessionController session;
  final BrowserActions browser;

  /// Set when the compiled API URL is unusable; the app then shows only that.
  final String? configError;
  final String initialLocation;

  /// Tests pin a locale; in the browser it follows navigator.languages.
  final Locale? locale;

  @override
  State<AdminApp> createState() => _AdminAppState();
}

class _AdminAppState extends State<AdminApp> {
  late final GoRouter _router = buildRouter(widget.session, initialLocation: widget.initialLocation);

  @override
  void dispose() {
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AdminScope(
      api: widget.api,
      session: widget.session,
      browser: widget.browser,
      child: MaterialApp.router(
        onGenerateTitle: (c) => AppLocalizations.of(c).appTitle,
        debugShowCheckedModeBanner: false,
        theme: AdminTheme.light,
        darkTheme: AdminTheme.dark,
        locale: widget.locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        routerConfig: _router,
        builder: widget.configError == null
            ? null
            : (context, _) => Scaffold(
                body: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(AppLocalizations.of(context).configError(widget.configError!)),
                  ),
                ),
              ),
      ),
    );
  }
}
