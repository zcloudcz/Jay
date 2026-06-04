import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app/app.dart';
import 'core/auth/app_lock.dart';
import 'core/network/api_client.dart';
import 'core/network/signalr_client.dart';
import 'core/network/webrtc_manager.dart';
import 'core/storage/database.dart';
import 'core/storage/secure_storage.dart';
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

  // Retrieve the device ID set during onboarding. Empty string is a safe
  // fallback — SignalR will connect but the server won't route messages
  // until onboarding completes and sets a real device ID.
  final deviceId = await secureStorage.getDeviceId() ?? '';

  // Base URL for all backend communication. Defaults to localhost for
  // development; production builds should override via environment config.
  const baseUrl = 'http://localhost:5000';

  final db = AppDatabase('calltype');
  final apiClient = ApiClient(baseUrl: baseUrl);
  final signalRClient = SignalRClient(baseUrl: baseUrl, deviceId: deviceId);

  runApp(
    MultiProvider(
      providers: [
        // -- Infrastructure providers (non-disposable) ----------------------
        // These are plain Provider.value because they don't extend
        // ChangeNotifier and have no dispose logic.
        Provider.value(value: db),
        Provider.value(value: apiClient),
        Provider.value(value: secureStorage),

        // -- Network providers (ChangeNotifier-based) -----------------------
        // SignalR and WebRTC are ChangeNotifiers so UI can react to
        // connection state changes (offline banner, call state).
        ChangeNotifierProvider.value(value: signalRClient),
        ChangeNotifierProvider(
          create: (ctx) => WebRTCManager(
            signalRClient: ctx.read<SignalRClient>(),
            apiClient: apiClient,
            myDeviceId: deviceId,
          ),
        ),

        // -- Feature controllers --------------------------------------------
        // Chat list and contacts controllers are app-wide singletons because
        // multiple screens reference them (e.g. group create reads contacts,
        // chat screen updates chat list timestamps).
        ChangeNotifierProvider(
          create: (_) => ChatListController(database: db),
        ),
        ChangeNotifierProvider(
          create: (_) => ContactsController(database: db),
        ),

        // -- Auth / security ------------------------------------------------
        Provider(create: (_) => AppLock(secureStorage: secureStorage)),
      ],
      child: const CallTypeApp(),
    ),
  );
}
