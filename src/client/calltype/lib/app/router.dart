import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/crypto/key_manager.dart';
import '../core/network/api_client.dart';
import '../core/network/webrtc_manager.dart';
import '../core/storage/database.dart';
import '../core/storage/secure_storage.dart';
import '../features/backup/backup_controller.dart';
import '../features/backup/backup_settings_screen.dart';
import '../features/backup/restore_screen.dart';
import '../features/calls/call_screen.dart';
import '../features/chat/chat_screen.dart';
import '../features/chat_list/chat_list_screen.dart';
import '../features/contacts/contacts_screen.dart';
import '../features/contacts/qr_scanner_screen.dart';
import '../features/groups/group_create_screen.dart';
import '../features/onboarding/onboarding_controller.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/settings/account_screen.dart';
import '../features/settings/app_lock_settings_screen.dart';
import '../features/settings/settings_screen.dart';

/// Central route configuration for the whole app.
///
/// Every screen has a route defined here. Routes read shared dependencies
/// (DB, API client, SignalR) from the provider tree set up in main.dart
/// instead of creating new instances inline. This ensures a single source
/// of truth for all services and proper lifecycle management.
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
        // OnboardingController is scoped to this route so the controller
        // (and its network resources) are disposed when the user navigates away.
        // Reads ApiClient and SecureStorage from the provider tree.
        return ChangeNotifierProvider(
          create: (ctx) => OnboardingController(
            apiClient: ctx.read<ApiClient>(),
            secureStorage: ctx.read<SecureStorage>(),
            // KeyManager is cheap to construct — it's a thin wrapper over
            // SecureStorage, so a route-scoped instance is fine here.
            keyManager: KeyManager(secureStorage: ctx.read<SecureStorage>()),
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
      builder: (context, state) {
        // ContactsController is already in the provider tree (app-wide),
        // so we don't need to wrap it in a route-scoped provider.
        return const ContactsScreen();
      },
      routes: [
        GoRoute(
          path: 'scan',
          builder: (context, state) => const QrScannerScreen(),
        ),
      ],
    ),
    GoRoute(
      path: '/groups/create',
      builder: (context, state) => const GroupCreateScreen(),
    ),
    GoRoute(
      path: '/call/:id',
      builder: (context, state) {
        // WebRTCManager is already in the provider tree (app-wide singleton).
        // The call screen reads it from context rather than creating a new
        // instance, ensuring a single peer connection lifecycle.
        return Builder(
          builder: (context) => CallScreen(
            webrtcManager: context.read<WebRTCManager>(),
          ),
        );
      },
    ),
    GoRoute(
      path: '/settings',
      builder: (context, state) => const SettingsScreen(),
      routes: [
        GoRoute(
          path: 'lock',
          builder: (context, state) {
            // AppLock is in the provider tree — the settings screen reads it.
            return const AppLockSettingsScreen();
          },
        ),
        GoRoute(
          path: 'account',
          builder: (context, state) {
            // AccountScreen reads ApiClient from the provider tree.
            return const AccountScreen();
          },
        ),
        GoRoute(
          path: 'backup',
          builder: (context, state) {
            // BackupController is scoped to this route because it holds
            // operation-specific state (progress, errors) that should reset
            // when the user navigates away and back.
            return ChangeNotifierProvider(
              create: (ctx) => BackupController(
                database: ctx.read<AppDatabase>(),
                apiClient: ctx.read<ApiClient>(),
                accountId: 'placeholder-account',
              ),
              child: const BackupSettingsScreen(),
            );
          },
          routes: [
            GoRoute(
              path: 'restore',
              builder: (context, state) {
                return ChangeNotifierProvider(
                  create: (ctx) => BackupController(
                    database: ctx.read<AppDatabase>(),
                    apiClient: ctx.read<ApiClient>(),
                    accountId: 'placeholder-account',
                  ),
                  child: const RestoreScreen(),
                );
              },
            ),
          ],
        ),
      ],
    ),
  ],
);
