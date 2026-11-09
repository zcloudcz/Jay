import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:calltype_core/crypto/key_manager.dart';
import 'package:calltype_core/crypto/session_manager.dart';
import 'package:calltype_core/network/api_client.dart';
import '../core/network/signalr_client.dart';
import '../core/network/webrtc_manager.dart';
import 'package:calltype_core/storage/database.dart';
import '../core/storage/secure_storage.dart';
import '../features/backup/backup_controller.dart';
import '../features/backup/backup_settings_screen.dart';
import '../features/backup/restore_screen.dart';
import 'package:calltype_core/network/channel_dtos.dart' show parseChannelLink;

import '../features/calls/call_screen.dart';
import '../features/channels/blocked_channels_screen.dart';
import '../features/channels/channel_moderation.dart';
import '../features/channels/channel_create_screen.dart';
import '../features/channels/channel_profile_screen.dart';
import '../features/channels/channel_screen.dart';
import '../features/channels/updates_screen.dart';
import '../features/chat/chat_controller.dart';
import '../features/chat/chat_screen.dart';
import '../features/chat/message_inbox_service.dart';
import '../features/chat/mentions.dart' show senderLabel;
import '../features/chat_list/chat_list_controller.dart';
import '../features/chat_list/chat_list_screen.dart';
import '../features/contacts/contacts_controller.dart';
import '../features/search/message_search.dart' show SearchHit;
import '../features/search/search_screen.dart';
import '../features/contacts/bot_link.dart';
import '../features/contacts/contacts_screen.dart';
import '../features/contacts/qr_scanner_screen.dart';
import '../features/devices/device_service.dart';
import '../features/devices/devices_screen.dart';
import '../features/devices/link_controllers.dart';
import '../features/devices/link_device_screen.dart';
import '../features/devices/link_ux.dart';
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
import '../features/notifications/notifications_screen.dart';
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
///   /onboarding?link=1 - link this device to a phone (link UX)
///   /chats             — main conversation list (initial location)
///   /chats/:id         — single conversation view
///   /chats/:id/search  - search inside that conversation (pops the hit id)
///   /search            - message search over all conversations
///   /contacts           — contact list / discovery
///   /contacts/scan      — QR code scanner for adding contacts
///   /updates            — followed channels ("Updates" tab)
///   /channels/…         — create, profile/:handle, feed/:id, admins/:id, blocked
///   /groups/create      — create a new group chat
///   /call/:id           — active voice/video call screen
///   /settings           — app settings root
///   /settings/lock      — PIN / biometric lock configuration
///   /settings/notifications - notifications on/off, preview, test
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
    // calltype://bot/<HANDLE>?start=<payload>: same mapping, to the screen
    // that adds (with confirmation) / opens the bot and pre-fills the chat.
    final botLink = parseBotLink(state.uri.toString());
    if (botLink != null) {
      return botLinkRoute(botLink);
    }
    final storage = context.read<SecureStorage>();
    final id = await storage.getDeviceId();
    final secret = await storage.getDeviceSecret();
    if ((id == null || secret == null) && state.uri.path != '/onboarding') {
      return '/onboarding';
    }
    // Link UX A1/A3: a device registered only to be linked stays on the link
    // screen until the phone has linked it or the user chose "start here".
    // Otherwise a page reload would leave it as an unintended new identity.
    if (state.uri.path != '/onboarding' &&
        await storage.read(linkPendingKey) != null) {
      if (!context.mounted) return null;
      if (!context.read<DeviceService>().isCompanion) return linkFirstRoute;
      // Linked, but the screen closed before it could drop the marker.
      await storage.delete(linkPendingKey);
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
          child: OnboardingScreen(
            linkFirst:
                isLinkFirstPlatform || state.uri.queryParameters['link'] == '1',
          ),
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
                final contacts = ctx.read<ContactsController>();
                final controller = ChatController(
                  database: ctx.read<AppDatabase>(),
                  signalRClient: ctx.read<SignalRClient>(),
                  sessionManager: ctx.read<SessionManager>(),
                  inbox: ctx.read<MessageInboxService>(),
                  apiClient: ctx.read<ApiClient>(),
                  conversationId: id,
                  directory: devices.directory,
                  // Replying in a 1:1 chat adds the peer as a contact (spec
                  // 2026-11-09-contacts-from-replies). Fire-and-forget from
                  // the root zone: it must never delay or fail the send.
                  onOwnSend: (messageId) => Zone.root.run(
                    () => unawaited(contacts.addPeerOnReply(messageId)),
                  ),
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
                // Bot deep link: only pre-filled, the user sends it.
                if (draft is ComposerDraft) {
                  controller.initialDraft = draft.text;
                }
                // Search result: open scrolled to that message.
                if (draft is JumpToMessage) controller.jumpTo(draft.messageId);
                return controller;
              },
              child: ChatScreen(contactId: id),
            );
          },
          routes: [
            // Search in this chat: the chat screen awaits the tapped hit's
            // message id and jumps there itself (its controller is not
            // reachable from this sibling page).
            GoRoute(
              path: 'search',
              builder: (context, state) => _searchScreen(
                context,
                conversationId: state.pathParameters['id']!,
                onOpen: (hit) => context.pop(hit.message.id),
              ),
            ),
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
      path: '/search',
      builder: (context, state) => _searchScreen(
        context,
        onOpen: (hit) => context.push(
          '/chats/${hit.message.conversationId}',
          extra: JumpToMessage(hit.message.id),
        ),
      ),
    ),
    GoRoute(
      path: '/bot/:handle',
      builder: (context, state) {
        // Re-validated here: the route can also be reached directly (web URL
        // bar), not only through the redirect above.
        final link = parseBotLink(
          Uri(
            scheme: 'calltype',
            host: 'bot',
            path: '/${state.pathParameters['handle']}',
            queryParameters: state.uri.queryParameters.isEmpty
                ? null
                : state.uri.queryParameters,
          ).toString(),
        );
        return link == null
            ? const ChatListScreen()
            : BotLinkScreen(link: link);
      },
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
      path: '/channels/reports',
      builder: (context, state) => const MyReportsScreen(),
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
          path: 'notifications',
          builder: (context, state) => const NotificationsScreen(),
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

/// The message search page with its names resolved from the providers
/// (spec 2026-11-08-chat-extras); [conversationId] limits it to one chat.
Widget _searchScreen(
  BuildContext context, {
  String? conversationId,
  required void Function(SearchHit hit) onOpen,
}) {
  final contacts = context.read<ContactsController>().contacts;
  final conversations = context.read<ChatListController>().conversations;
  return SearchScreen(
    database: context.read<AppDatabase>(),
    myIdentityId: context.read<DeviceService>().directory.selfIdentityId,
    conversationId: conversationId,
    conversationTitle: (id) {
      final conversation = conversations.where((c) => c.id == id).firstOrNull;
      final contact = contacts.where((c) => c.deviceId == id).firstOrNull;
      return conversation?.title ??
          contact?.displayName ??
          contact?.userHandle ??
          id;
    },
    senderName: (id) => senderLabel(id, members: const [], contacts: contacts),
    onOpen: onOpen,
  );
}
