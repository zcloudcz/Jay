import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app/app.dart';
import 'core/auth/app_lock.dart';
import 'core/auth/auth_service.dart';
import 'core/config/firebase_config.dart';
import 'core/crypto/key_manager.dart';
import 'core/crypto/session_manager.dart';
import 'core/network/api_client.dart';
import 'core/network/push_service.dart';
import 'core/network/signalr_client.dart';
import 'core/network/webrtc_manager.dart';
import 'core/notifications/call_notifications.dart';
import 'core/storage/database.dart';
import 'core/storage/secure_storage.dart';
import 'features/calls/call_event_sender.dart';
import 'features/channels/channels_controller.dart';
import 'features/chat/active_conversation.dart';
import 'features/chat/chat_extensions.dart';
import 'features/chat/message_inbox_service.dart';
import 'features/chat_list/chat_list_controller.dart';
import 'features/contacts/contacts_controller.dart';

/// Application entry point with full dependency injection wiring.
///
/// All shared services are created here and provided to the widget tree
/// via MultiProvider. This ensures:
///   - Single instances of DB, API client, and SignalR across the app
///   - No inline construction of services in route builders
///   - Easy testability — swap providers in test harness
///   - Proper lifecycle management (ChangeNotifierProviders auto-dispose)
///
/// The initialization is async because we need the device ID from secure
/// storage before constructing SignalR (it's used as a query parameter
/// for connection identity).
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final secureStorage = SecureStorage();
  // iOS: rewrite keychain items to "after first unlock" BEFORE the first
  // read, so a call push that launches the app on a locked iPhone can still
  // read the device id and secret. No-op elsewhere; never throws.
  await secureStorage.migrateKeychainAccessibility();

  // Retrieve the device ID set during onboarding. Empty string is a safe
  // fallback — SignalR will connect but the server won't route messages
  // until onboarding completes and sets a real device ID.
  final deviceId = await secureStorage.getDeviceId() ?? '';

  // Base URL for all backend communication. Defaults to localhost for
  // development; production builds should override via environment config.
  const baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8080',
  );

  final db = openAppDatabase('calltype');

  // AuthService exchanges the device secret (stored at registration) for
  // short-lived JWTs. ApiClient attaches them as Bearer headers; SignalR
  // passes them as access_token during the WebSocket handshake. Without
  // this, every protected endpoint returns 401.
  final authService = AuthService(
    secureStorage: secureStorage,
    baseUrl: baseUrl,
  );

  final apiClient = ApiClient(baseUrl: baseUrl, authService: authService);
  final signalRClient = SignalRClient(
    baseUrl: baseUrl,
    deviceId: deviceId,
    authService: authService,
  );

  // E2E crypto services. Single instances app-wide: KeyManager wraps secure
  // storage (identity + pre-keys), SessionManager owns Double Ratchet session
  // state in the local DB. Both are needed by every chat screen.
  final keyManager = KeyManager(secureStorage: secureStorage);
  final sessionManager = SessionManager(database: db, keyManager: keyManager);

  // Built here (not inside a provider `create:`) so its callReports stream
  // can be wired to CallEventSender below, app-wide and before runApp.
  final webrtcManager = WebRTCManager(
    signalRClient: signalRClient,
    apiClient: apiClient,
    myDeviceId: deviceId,
  );

  // App-wide inbox: decrypts + persists EVERY incoming message, even when
  // no chat screen is open. Must start before SignalR connects — the server
  // flushes queued (offline) messages immediately on connect and deletes
  // them after delivery, so a late subscriber would lose them permanently.
  final inbox = MessageInboxService(
    database: db,
    sessionManager: sessionManager,
    incomingMessages: signalRClient.onMessage,
    apiClient: apiClient,
    acknowledge: signalRClient.acknowledgeMessage,
  );
  inbox.start();

  // H2: archives every business call as a `call-event` group message as
  // soon as it ends, whether or not that conversation's chat screen is open
  // — same "app-wide, starts before connect" reasoning as the inbox above.
  final callEventSender = CallEventSender(
    database: db,
    signalRClient: signalRClient,
    sessionManager: sessionManager,
    apiClient: apiClient,
    callReports: webrtcManager.callReports,
  );
  callEventSender.start();

  // Channels (public posts, NOT end-to-end encrypted — kept apart from the
  // inbox above on purpose). Created before SignalR connects for the same
  // reason as the inbox: hub events must find a subscriber.
  final channels = ChannelsController(
    database: db,
    apiClient: apiClient,
    channelPosts: signalRClient.onChannelPost,
    channelDeleted: signalRClient.onChannelDeleted,
    joinChannels: signalRClient.joinChannels,
    leaveChannel: signalRClient.leaveChannel,
  );
  await channels.load();
  // The server keeps no offline queue for channels, so every transition to
  // "connected" (app start, reconnect, first connect after onboarding) pulls
  // what was missed and re-joins the hub groups. One sync per transition —
  // not a polling loop.
  var wasConnected = false;
  signalRClient.addListener(() {
    final connected = signalRClient.connected;
    if (connected && !wasConnected) {
      unawaited(channels.sync().catchError((Object _) {}));
    }
    wasConnected = connected;
  });

  await sessionManager.finalizePreKeyCleanup();
  if (deviceId.isNotEmpty) {
    unawaited(signalRClient.connect().catchError((Object _) {}));
  }

  // Initialize push notifications if the device is registered.
  // Fire-and-forget — push is best-effort and must never block app startup.
  // If Firebase is not configured (no google-services.json / GoogleService-Info.plist),
  // PushService.initialize() catches the error and the app works without push.
  if (deviceId.isNotEmpty) {
    final push = PushService(
      apiClient,
      deviceId,
      // A channel push means the hub was down (the server only pushes to
      // offline followers): pull the missed posts. If the hub is up again
      // meanwhile, sync() finds nothing new and is cheap.
      onChannelPost: () => unawaited(channels.sync().catchError((Object _) {})),
    );
    // Builds with FIREBASE_* dart-defines (release, stream P3b) initialize
    // the default app with those options first; PushService's own
    // Firebase.initializeApp() then reuses it. Builds without defines (dev,
    // CI, today's deploys) skip this and behave exactly as before.
    unawaited(
      FirebaseConfig.initializeIfConfigured().then((_) => push.initialize()),
    );
  }

  // Wave-0 seams (docs/superpowers/plans/2026-09-29-gap-contracts.md §5):
  // created here so the streams of wave 1 only swap the value.
  // Set by the chat screen (M); read by notifications (N) and receipts (M04).
  final activeConversation = ActiveConversation();

  runApp(
    MultiProvider(
      providers: [
        // -- Infrastructure providers (non-disposable) ----------------------
        // These are plain Provider.value because they don't extend
        // ChangeNotifier and have no dispose logic.
        Provider.value(value: db),
        Provider.value(value: apiClient),
        Provider.value(value: authService),
        Provider.value(value: secureStorage),
        Provider.value(value: keyManager),
        Provider.value(value: sessionManager),
        Provider.value(value: inbox),
        // No-op until stream N implements web/desktop/missed-call
        // notifications; stream C calls it unconditionally.
        Provider<CallNotifications>.value(value: const NoopCallNotifications()),
        // No extra message types until stream M2 plugs in media (M2-10).
        Provider<ChatExtensions>.value(value: ChatExtensions.none),
        ChangeNotifierProvider<ActiveConversation>.value(
          value: activeConversation,
        ),

        // -- Network providers (ChangeNotifier-based) -----------------------
        // SignalR and WebRTC are ChangeNotifiers so UI can react to
        // connection state changes (offline banner, call state).
        ChangeNotifierProvider.value(value: signalRClient),
        ChangeNotifierProvider.value(value: webrtcManager),

        // -- Feature controllers --------------------------------------------
        // Chat list and contacts controllers are app-wide singletons because
        // multiple screens reference them (e.g. group create reads contacts,
        // chat screen updates chat list timestamps).
        ChangeNotifierProvider(create: (_) => ChatListController(database: db)),
        ChangeNotifierProvider(
          create: (_) => ContactsController(database: db, apiClient: apiClient),
        ),
        ChangeNotifierProvider.value(value: channels),

        // -- Auth / security ------------------------------------------------
        Provider(create: (_) => AppLock(secureStorage: secureStorage)),
      ],
      child: const CallTypeApp(),
    ),
  );
}
