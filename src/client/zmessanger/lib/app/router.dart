import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/network/api_client.dart';
import '../core/storage/secure_storage.dart';
import '../features/chat/chat_screen.dart';
import '../features/chat_list/chat_list_screen.dart';
import '../features/onboarding/onboarding_controller.dart';
import '../features/onboarding/onboarding_screen.dart';

/// Central route configuration for the whole app.
///
/// Every screen that will exist in the app has a route defined here, even
/// if the destination widget is just a placeholder today. This lets us wire
/// up navigation early and replace placeholders incrementally as features
/// are implemented.
///
/// Route hierarchy:
///   /onboarding        — first-run device setup
///   /chats             — main conversation list (initial location)
///   /chats/:id         — single conversation view
///   /contacts           — contact list / discovery
///   /contacts/scan      — QR code scanner for adding contacts
///   /groups/create      — create a new group chat
///   /call/:id           — active voice/video call screen
///   /settings           — app settings root
///   /settings/lock      — PIN / biometric lock configuration
///   /settings/account   — account registration & management
///   /settings/backup    — encrypted backup settings
final router = GoRouter(
  initialLocation: '/chats',
  routes: [
    GoRoute(
      path: '/onboarding',
      builder: (context, state) {
        // Provider is scoped to this route so the controller (and its
        // network resources) are disposed when the user navigates away.
        // The base URL defaults to localhost for development; it will be
        // configurable via environment/build flavors in production.
        return ChangeNotifierProvider(
          create: (_) => OnboardingController(
            apiClient: ApiClient(baseUrl: 'http://localhost:5000'),
            secureStorage: SecureStorage(),
          ),
          child: const OnboardingScreen(),
        );
      },
    ),
    GoRoute(
      path: '/chats',
      builder: (context, state) => const ChatListScreen(),
      routes: [
        GoRoute(
          path: ':id',
          builder: (context, state) {
            final id = state.pathParameters['id']!;
            return ChatScreen(contactId: id);
          },
        ),
      ],
    ),
    GoRoute(
      path: '/contacts',
      builder: (context, state) => const _Placeholder('Contacts'),
      routes: [
        GoRoute(
          path: 'scan',
          builder: (context, state) => const _Placeholder('Scan QR'),
        ),
      ],
    ),
    GoRoute(
      path: '/groups/create',
      builder: (context, state) => const _Placeholder('Create Group'),
    ),
    GoRoute(
      path: '/call/:id',
      builder: (context, state) {
        final id = state.pathParameters['id']!;
        return _Placeholder('Call $id');
      },
    ),
    GoRoute(
      path: '/settings',
      builder: (context, state) => const _Placeholder('Settings'),
      routes: [
        GoRoute(
          path: 'lock',
          builder: (context, state) => const _Placeholder('Lock Settings'),
        ),
        GoRoute(
          path: 'account',
          builder: (context, state) => const _Placeholder('Account Settings'),
        ),
        GoRoute(
          path: 'backup',
          builder: (context, state) => const _Placeholder('Backup Settings'),
        ),
      ],
    ),
  ],
);

/// Temporary placeholder widget used for routes whose screens are not yet
/// implemented. Displays the screen name so navigation can be verified
/// visually during development.
class _Placeholder extends StatelessWidget {
  const _Placeholder(this.name);

  final String name;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(name)),
      body: Center(
        child: Text(
          name,
          style: Theme.of(context).textTheme.headlineMedium,
        ),
      ),
    );
  }
}
