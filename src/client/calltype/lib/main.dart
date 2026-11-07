import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app/app.dart';
import 'app/router.dart';
import 'core/auth/app_lock.dart';
import 'core/auth/auth_service.dart';
import 'core/crypto/key_manager.dart';
import 'core/crypto/session_manager.dart';
import 'core/network/api_client.dart';
import 'core/network/signalr_client.dart';
import 'core/network/webrtc_manager.dart';
import 'core/storage/database.dart';
import 'core/storage/secure_storage.dart';
import 'features/calls/call_event_sender.dart';
import 'features/channels/channels_controller.dart';
import 'features/chat/message_inbox_service.dart';
import 'features/chat_list/chat_list_controller.dart';
import 'features/contacts/contacts_controller.dart';
import 'features/devices/device_service.dart';
import 'features/media/media_service.dart';
import 'features/media/media_store.dart';
import 'features/mute/mute_controller.dart';
import 'features/notifications/notification_directory.dart';
import 'features/notifications/notification_platform.dart';
import 'features/notifications/notification_service.dart';
import 'l10n/l10n.dart';

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
  // Encrypted media relay (uploads, downloads, local copies): one service
  // for the app so a transfer survives leaving the chat screen.
  MediaService.instance = MediaService(
    remote: ApiMediaRemote(apiClient),
    store: MediaStore.create(),
  );
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

  // Multi-device: owns the verified device lists, the companion state and the
  // device's own list. Opened before the inbox can see a message: routing
  // needs selfIdentityId (constraint 8). A fresh install opens it in the
  // onboarding route instead.
  final devices = DeviceService(
    database: db,
    apiClient: apiClient,
    keyManager: keyManager,
    sessionManager: sessionManager,
    signalRClient: signalRClient,
  );
  if (deviceId.isNotEmpty) await devices.open(deviceId);

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
    directory: () => devices.directory,
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
  // Conversation mutes (spec D6) live on the server per device; this is
  // only the cache behind the list icons and the Chats badge.
  final mutes = MuteController(apiClient: apiClient);

  // Local notifications for messages, calls and channel posts, plus the
  // server push registration (spec 2026-11-06). App-wide and subscribed
  // before SignalR connects, like the inbox: the first queued messages
  // flushed on connect must already produce notifications.
  final notifications = NotificationService(
    notifier: createLocalNotifier(),
    prefs: SecureStoragePrefs(secureStorage),
    // No BuildContext here: the texts follow the same OS locale resolution
    // MaterialApp uses (no in-app language switch exists).
    strings: () => lookupAppLocalizations(_appLocale()),
    directory: AppNotificationDirectory(
      database: db,
      devices: devices,
      channels: channels,
    ),
    currentPath: () {
      try {
        return router.routerDelegate.currentConfiguration.uri.path;
      } catch (_) {
        return null;
      }
    },
    // "Foreground and focused" (spec section 2): a minimized window or a
    // background tab still gets notifications for the open chat.
    appFocused: () =>
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
        webDocumentFocused,
    openRoute: _openNotificationRoute,
    muteOf: mutes.modeOf,
    apiClient: apiClient,
    pushProvider: createPushProvider(apiClient),
    deviceId: () => devices.isOpen ? devices.directory.selfDeviceId : null,
    // Contract 1.1: the server localizes its generic push texts by this.
    locale: () => _appLocale().toLanguageTag(),
    // A channel push means the hub was down (the server only pushes to
    // offline followers): pull the missed posts. If the hub is up again
    // meanwhile, sync() finds nothing new and is cheap.
    onForegroundPush: (data) {
      if (data['type'] == 'channel_post') {
        unawaited(channels.sync().catchError((Object _) {}));
      }
    },
  );
  inbox.persistedMessages.listen((m) => unawaited(notifications.onMessage(m)));
  channels.newPosts.listen((p) => unawaited(notifications.onChannelPost(p)));
  // An incoming call while the app is in the background: ring visibly. The
  // notification is withdrawn as soon as the call stops ringing.
  var ringingFrom = '';
  webrtcManager.addListener(() {
    final remote = webrtcManager.remoteDeviceId;
    final ringing = webrtcManager.isIncoming && remote != null;
    if (ringing && remote != ringingFrom) {
      ringingFrom = remote;
      unawaited(notifications.onIncomingCall(remote));
    } else if (!ringing && ringingFrom.isNotEmpty) {
      ringingFrom = '';
      unawaited(notifications.onCallNotRinging());
    }
  });
  unawaited(notifications.start());
  // Back from the system settings (or another app): the permission may have
  // changed there.
  AppLifecycleListener(
    onResume: () => unawaited(notifications.refreshPermission()),
  );
  // The server keeps no offline queue for channels, so every transition to
  // "connected" (app start, reconnect, first connect after onboarding) pulls
  // what was missed and re-joins the hub groups. One sync per transition —
  // not a polling loop.
  var wasConnected = false;
  signalRClient.addListener(() {
    final connected = signalRClient.connected;
    if (connected && !wasConnected) {
      unawaited(channels.sync().catchError((Object _) {}));
      // A DeviceListChanged hint sent while this device was offline is lost,
      // so a (re)connect re-checks the own list (cheap no-op when unlinked).
      if (devices.isOpen) unawaited(devices.checkOwnList());
      // A connect is the first moment the device is surely registered (also
      // right after onboarding), and after an outage the chat list may have
      // loaded while GET /mutes failed; one cheap re-read per transition.
      unawaited(mutes.load().catchError((Object _) {}));
      // First connect after onboarding = the moment for the one automatic
      // permission prompt (mobile); every connect re-registers the push
      // token, which also retries a registration that failed offline.
      unawaited(notifications.onConnected());
    }
    wasConnected = connected;
  });

  await sessionManager.finalizePreKeyCleanup();
  if (deviceId.isNotEmpty) {
    unawaited(signalRClient.connect().catchError((Object _) {}));
  }

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

        // -- Network providers (ChangeNotifier-based) -----------------------
        // SignalR and WebRTC are ChangeNotifiers so UI can react to
        // connection state changes (offline banner, call state).
        ChangeNotifierProvider.value(value: signalRClient),
        ChangeNotifierProvider.value(value: webrtcManager),
        ChangeNotifierProvider.value(value: devices),

        // -- Feature controllers --------------------------------------------
        // Chat list and contacts controllers are app-wide singletons because
        // multiple screens reference them (e.g. group create reads contacts,
        // chat screen updates chat list timestamps).
        ChangeNotifierProvider(create: (_) => ChatListController(database: db)),
        ChangeNotifierProvider(
          create: (_) => ContactsController(database: db, apiClient: apiClient),
        ),
        ChangeNotifierProvider.value(value: channels),
        ChangeNotifierProvider.value(value: mutes),
        ChangeNotifierProvider.value(value: notifications),

        // -- Auth / security ------------------------------------------------
        Provider(create: (_) => AppLock(secureStorage: secureStorage)),
      ],
      child: const CallTypeApp(),
    ),
  );
}

/// The UI language: the OS preference list resolved against the shipped
/// locales, exactly like MaterialApp without a `locale:` does.
Locale _appLocale() => basicLocaleListResolution(
  PlatformDispatcher.instance.locales,
  AppLocalizations.supportedLocales,
);

/// Opens what a tapped notification points at. Deferred to after a frame:
/// a tap that launched the app arrives before the router has built anything.
void _openNotificationRoute(String route) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (route.startsWith('/channels/')) {
      // The feed is a top-level route: put the Updates tab under it so Back
      // returns into the app instead of leaving it.
      router.go('/updates');
      unawaited(router.push(route));
    } else {
      router.go(route);
    }
  });
  WidgetsBinding.instance.scheduleFrame();
}
