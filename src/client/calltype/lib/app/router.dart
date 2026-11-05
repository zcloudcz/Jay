import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/crypto/key_manager.dart';
import '../core/crypto/session_manager.dart';
import '../core/network/api_client.dart';
import '../core/network/signalr_client.dart';
import '../core/network/webrtc_manager.dart';
import '../core/storage/database.dart';
import '../core/storage/secure_storage.dart';
import '../features/backup/backup_controller.dart';
import '../features/backup/backup_settings_screen.dart';
import '../features/backup/restore_screen.dart';
import 'package:calltype_core/network/channel_dtos.dart' show parseChannelLink;

import '../features/calls/call_screen.dart';
import '../features/channels/blocked_channels_screen.dart';
import '../features/channels/channel_create_screen.dart';
import '../features/channels/channel_profile_screen.dart';
import '../features/channels/channel_screen.dart';
import '../features/channels/updates_screen.dart';
import '../features/chat/chat_controller.dart';
import '../features/chat/chat_screen.dart';
import '../features/chat/message_inbox_service.dart';
import '../features/chat_list/chat_list_screen.dart';
import '../features/contacts/contacts_screen.dart';
import '../features/contacts/qr_scanner_screen.dart';
import '../features/devices/device_service.dart';
import '../features/devices/devices_screen.dart';
import '../features/devices/link_controllers.dart';
import '../features/devices/link_device_screen.dart';
import '../features/groups/bot_talk_controller.dart';
import '../features/groups/bot_talk_screen.dart';
import '../features/groups/group_create_screen.dart';
import '../features/organization/emergency/emergency_controller.dart';
import '../features/organization/emergency/emergency_enroll_screen.dart';
import '../features/organization/emergency/emergency_screen.dart';
import '../features/organization/organization_controller.dart';
import '../features/organization/organization_screen.dart';
import '../features/onboarding/onboarding_controller.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/settings/account_screen.dart';
import '../features/settings/app_lock_settings_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/settings/identity_screen.dart';

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
///   /updates            — followed channels ("Updates" tab)
///   /channels/…         — create, profile/:handle, feed/:id, admins/:id, blocked
///   /groups/create      — create a new group chat
///   /call/:id           — active voice/video call screen
///   /settings           — app settings root
///   /settings/lock      — PIN / biometric lock configuration
///   /settings/account   — account registration & management
///   /settings/backup    — encrypted backup settings
final router = GoRouter(
  initialLocation: '/chats',
  redirect: (context, state) async {
    // Deep link / QR: calltype://channel/<handle> arrives here as a URI with
    // a custom scheme, which matches no route — map it to the profile route.
    // The onboarding check still applies on the next redirect pass.
    final channelHandle = parseChannelLink(state.uri.toString());
    if (channelHandle != null) {
      return '/channels/profile/${Uri.encodeComponent(channelHandle)}';
    }
    final storage = context.read<SecureStorage>();
    final id = await storage.getDeviceId();
    final secret = await storage.getDeviceSecret();
    if ((id == null || secret == null) && state.uri.path != '/onboarding') {
      return '/onboarding';
    }
    if (state.uri.path.startsWith('/settings/backup') &&
        await storage.getAccountId() == null) {
      return '/settings/account';
    }
    return null;
  },
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
            onRegistered: (id) async {
              // Read before the await: ctx must not be used across an async gap.
              final connection = ctx.read<SignalRClient>();
              // Before connecting: the inbox routes through the directory from
              // the first queued message on.
              await ctx.read<DeviceService>().open(id);
              connection.setDeviceId(id);
              // Registration is complete even if the first socket attempt fails.
              try {
                await connection.connect();
              } catch (_) {}
            },
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
            // ChatController is scoped to this route — it subscribes to the
            // SignalR message stream for ONE conversation and must cancel
            // that subscription when the user navigates away (auto-dispose
            // via ChangeNotifierProvider).
            return ChangeNotifierProvider(
              create: (ctx) {
                final devices = ctx.read<DeviceService>();
                final controller = ChatController(
                  database: ctx.read<AppDatabase>(),
                  signalRClient: ctx.read<SignalRClient>(),
                  sessionManager: ctx.read<SessionManager>(),
                  inbox: ctx.read<MessageInboxService>(),
                  apiClient: ctx.read<ApiClient>(),
                  conversationId: id,
                  directory: devices.directory,
                  // Never takes the processing queue, so fire-and-forget is
                  // safe from inside a send.
                  onMissingOwnDevice: (d) =>
                      unawaited(devices.reportVanishedCompanions([d])),
                  // Fire-and-forget: this runs inside the processing queue and
                  // must never wait for a queue job. The server's stale answer
                  // is only a hint; reportVanishedCompanions records it and
                  // the user decides (it never re-signs on its own).
                  onStale: (required) => unawaited(() async {
                    final wanted = {for (final d in required) d.toLowerCase()};
                    // devicesOf lists the primary first; only its companions
                    // can have vanished.
                    final own = await devices.directory.devicesOf(
                      devices.directory.selfDeviceId,
                    );
                    await devices.reportVanishedCompanions(
                      own.skip(1).where((d) => !wanted.contains(d)),
                    );
                  }()),
                );
                // Forward: the message to forward arrives as route `extra`.
                // `create` runs once per route, so it is sent exactly once,
                // by the controller of the chat the user is now looking at.
                final draft = state.extra;
                if (draft is ForwardDraft) {
                  controller
                      .sendForwarded(body: draft.body, type: draft.type)
                      .catchError((_) {});
                }
                return controller;
              },
              child: ChatScreen(contactId: id),
            );
          },
          routes: [
            // Group "Bot conversation" setting. Its own route-scoped
            // controller: it listens to GroupChanged hints only while open.
            GoRoute(
              path: 'bot-talk',
              builder: (context, state) {
                final id = state.pathParameters['id']!;
                return ChangeNotifierProvider(
                  create: (ctx) => BotTalkController(
                    apiClient: ctx.read<ApiClient>(),
                    groupId: id,
                    // THIS device (not the identity): admin rights belong
                    // to member rows, and a companion has none.
                    selfDeviceId: ctx
                        .read<DeviceService>()
                        .directory
                        .selfDeviceId,
                    groupChanged: ctx.read<SignalRClient>().onGroupChanged,
                  ),
                  child: const BotTalkScreen(),
                );
              },
            ),
          ],
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
          builder: (context, state) =>
              !kIsWeb &&
                  (defaultTargetPlatform == TargetPlatform.windows ||
                      defaultTargetPlatform == TargetPlatform.linux)
              ? const ContactsScreen()
              : const QrScannerScreen(),
        ),
      ],
    ),
    // Channels (public, NOT end-to-end encrypted). ChannelsController is
    // app-wide (main.dart), so these routes need no scoped providers.
    GoRoute(
      path: '/updates',
      builder: (context, state) => const UpdatesScreen(),
    ),
    GoRoute(
      path: '/channels/create',
      builder: (context, state) => const ChannelCreateScreen(),
    ),
    GoRoute(
      path: '/channels/blocked',
      builder: (context, state) => const BlockedChannelsScreen(),
    ),
    GoRoute(
      path: '/channels/profile/:handle',
      builder: (context, state) =>
          ChannelProfileScreen(handle: state.pathParameters['handle']!),
    ),
    GoRoute(
      path: '/channels/feed/:id',
      builder: (context, state) =>
          ChannelScreen(channelId: state.pathParameters['id']!),
    ),
    GoRoute(
      path: '/channels/admins/:id',
      builder: (context, state) =>
          ChannelAdminsScreen(channelId: state.pathParameters['id']!),
    ),
    GoRoute(
      path: '/groups/create',
      builder: (context, state) => GroupCreateScreen(
        organizationId: state.uri.queryParameters['orgId'],
        organizationName: state.uri.queryParameters['orgName'],
      ),
    ),
    GoRoute(
      path: '/call/:id',
      builder: (context, state) {
        // WebRTCManager is already in the provider tree (app-wide singleton).
        // The call screen reads it from context rather than creating a new
        // instance, ensuring a single peer connection lifecycle.
        return Builder(
          builder: (context) =>
              CallScreen(webrtcManager: context.read<WebRTCManager>()),
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
          path: 'identity',
          builder: (context, state) => const IdentityScreen(),
        ),
        GoRoute(
          path: 'devices',
          builder: (context, state) => const DevicesScreen(),
          routes: [
            GoRoute(
              path: 'link',
              builder: (context, state) => ChangeNotifierProvider(
                create: (ctx) {
                  final controller = CompanionLinkController(
                    database: ctx.read<AppDatabase>(),
                    devices: ctx.read<DeviceService>(),
                    keyManager: ctx.read<KeyManager>(),
                    signalRClient: ctx.read<SignalRClient>(),
                  );
                  unawaited(controller.start());
                  return controller;
                },
                child: const LinkDeviceScreen(),
              ),
            ),
          ],
        ),
        GoRoute(
          path: 'account',
          builder: (context, state) {
            // AccountScreen reads ApiClient from the provider tree.
            return const AccountScreen();
          },
        ),
        GoRoute(
          path: 'organization',
          builder: (context, state) => ChangeNotifierProvider(
            // load() is NOT chained here: it can hit `mfa_required`, and the
            // screen must wire OrganizationController.promptForMfa (which
            // needs a BuildContext for the dialog) before the first call.
            create: (ctx) =>
                OrganizationController(apiClient: ctx.read<ApiClient>()),
            child: const OrganizationScreen(),
          ),
          routes: [
            GoRoute(
              path: 'emergency',
              builder: (context, state) {
                final organizationId = state.uri.queryParameters['orgId']!;
                return ChangeNotifierProvider(
                  create: (ctx) => EmergencyController(
                    apiClient: ctx.read<ApiClient>(),
                    organizationId: organizationId,
                  ),
                  child: EmergencyScreen(organizationId: organizationId),
                );
              },
            ),
            GoRoute(
              path: 'emergency-enroll',
              builder: (context, state) => ChangeNotifierProvider(
                create: (ctx) => EmergencyEnrollController(
                  apiClient: ctx.read<ApiClient>(),
                  database: ctx.read<AppDatabase>(),
                ),
                child: const EmergencyEnrollScreen(),
              ),
            ),
          ],
        ),
        GoRoute(
          path: 'backup',
          builder: (context, state) {
            // BackupController is scoped to this route because it holds
            // operation-specific state (progress, errors) that should reset
            // when the user navigates away and back.
            return const _BackupRoute(restore: false);
          },
          routes: [
            GoRoute(
              path: 'restore',
              builder: (context, state) {
                return const _BackupRoute(restore: true);
              },
            ),
          ],
        ),
      ],
    ),
  ],
);

class _BackupRoute extends StatefulWidget {
  const _BackupRoute({required this.restore});
  final bool restore;
  @override
  State<_BackupRoute> createState() => _BackupRouteState();
}

class _BackupRouteState extends State<_BackupRoute> {
  late Future<String?> _account;
  @override
  void initState() {
    super.initState();
    _account = context.read<SecureStorage>().getAccountId();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<String?>(
    future: _account,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      if (snapshot.hasError || snapshot.data == null) {
        return const AccountScreen();
      }
      return ChangeNotifierProvider(
        create: (ctx) => BackupController(
          database: ctx.read<AppDatabase>(),
          apiClient: ctx.read<ApiClient>(),
          accountId: snapshot.data!,
        ),
        child: widget.restore
            ? const RestoreScreen()
            : const BackupSettingsScreen(),
      );
    },
  );
}
