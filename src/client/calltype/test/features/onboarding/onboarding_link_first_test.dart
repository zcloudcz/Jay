import 'package:calltype_core/crypto/key_manager.dart';
import 'package:calltype/core/network/signalr_client.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:calltype/core/storage/secure_storage.dart';
import 'package:calltype/features/devices/device_service.dart';
import 'package:calltype/features/devices/link_ux.dart';
import 'package:calltype/features/onboarding/onboarding_controller.dart';
import 'package:calltype/features/onboarding/onboarding_screen.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../helpers/fake_multi_device_server.dart';
import '../../helpers/localized_app.dart';
import '../../helpers/test_device.dart';

const webId = 'a0000000-0000-4000-8000-000000000002';
const webHandle = 'CT-WEBB-0002';

/// The server's answer to POST /devices, counted.
class _RegisteringApi extends FakeDeviceApi {
  _RegisteringApi(super.server);
  int registrations = 0;

  @override
  Future<Map<String, dynamic>> registerDevice({
    required String identityKey,
    required String signedPreKey,
    required List<Map<String, dynamic>> oneTimePreKeys,
    String? signingKey,
    String? signature,
    bool? isBot,
  }) async {
    registrations++;
    return {
      'deviceId': webId,
      'userHandle': webHandle,
      'deviceSecret': 'secret',
    };
  }
}

/// Link UX A1: web and desktop lead with the link code; "start here" is the
/// standalone path. linkFirst is injected instead of depending on kIsWeb.
void main() {
  late FakeMultiDeviceServer server;
  late TestDevice web;
  late _RegisteringApi api;
  late DeviceService devices;
  late OnboardingController controller;

  Future<void> setUpWeb(WidgetTester tester) async {
    await tester.runAsync(() async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      server = FakeMultiDeviceServer();
      web = await TestDevice.create(webId);
      server.add(web);
      api = _RegisteringApi(server);
      final hub = server.hubs[webId] = FakeHubClient(server, webId);
      devices = DeviceService(
        database: web.db,
        apiClient: api,
        keyManager: web.keys,
        sessionManager: web.sessions,
        signalRClient: hub,
      );
      controller = OnboardingController(
        apiClient: api,
        secureStorage: web.secureStorage,
        keyManager: web.keys,
        onRegistered: devices.open,
      );
    });
  }

  Future<void> pump(WidgetTester tester, {required bool linkFirst}) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<AppDatabase>.value(value: web.db),
          Provider<KeyManager>.value(value: web.keys),
          Provider<SecureStorage>.value(value: web.secureStorage),
          ChangeNotifierProvider<SignalRClient>.value(
            value: server.hubs[webId]!,
          ),
          ChangeNotifierProvider<DeviceService>.value(value: devices),
          ChangeNotifierProvider<OnboardingController>.value(value: controller),
        ],
        child: localizedApp(home: OnboardingScreen(linkFirst: linkFirst)),
      ),
    );
    await settle(tester);
  }

  Future<void> tearDownWeb(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      controller.dispose();
      devices.dispose();
      await server.close();
      await web.close();
    });
  }

  testWidgets('web: the link code comes first, without a new identity', (
    tester,
  ) async {
    await setUpWeb(tester);
    await pump(tester, linkFirst: true);

    expect(find.text(l10nEn.linkFirstTitle), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text(l10nEn.linkStepOpenPhone), findsOneWidget);
    expect(
      find.text(l10nEn.linkStepTapEntry(l10nEn.linkWebAction)),
      findsOneWidget,
    );
    expect(find.text(l10nEn.linkFirstStandalone), findsOneWidget);
    // Registered silently for the code, but never shown as "your identity".
    expect(api.registrations, 1);
    expect(find.text(l10nEn.onboardingGetStarted), findsNothing);
    expect(find.text(l10nEn.onboardingYourIdentity), findsNothing);
    expect(find.text(webHandle), findsNothing);
    expect(
      await tester.runAsync(() => web.secureStorage.read(linkPendingKey)),
      '1',
      reason: 'a reload must come back to the link screen',
    );
    await tearDownWeb(tester);
  });

  testWidgets('web: "start here" shows the identity and reuses the device', (
    tester,
  ) async {
    await setUpWeb(tester);
    await pump(tester, linkFirst: true);

    await tester.tap(find.text(l10nEn.linkFirstStandalone));
    await settle(tester);

    expect(find.text(l10nEn.onboardingYourIdentity), findsOneWidget);
    expect(find.text(webHandle), findsOneWidget);
    expect(find.text(l10nEn.onboardingStartMessaging), findsOneWidget);
    expect(find.text(l10nEn.linkFirstTitle), findsNothing);
    expect(api.registrations, 1, reason: 'no second device is created');
    expect(
      await tester.runAsync(() => web.secureStorage.read(linkPendingKey)),
      isNull,
    );
    await tearDownWeb(tester);
  });

  testWidgets(
    'web: "start here" before any registration creates the identity',
    (tester) async {
      await setUpWeb(tester);
      // Not pumped yet: the controller is driven straight to the standalone
      // path, as a tap before the silent registration would.
      await tester.runAsync(controller.startStandalone);
      await pump(tester, linkFirst: false);

      expect(api.registrations, 1);
      expect(find.text(webHandle), findsOneWidget);
      await tearDownWeb(tester);
    },
  );

  testWidgets('mobile keeps "Get started"', (tester) async {
    await setUpWeb(tester);
    await pump(tester, linkFirst: false);

    expect(find.text(l10nEn.onboardingGetStarted), findsOneWidget);
    expect(find.text(l10nEn.linkFirstTitle), findsNothing);
    expect(api.registrations, 0);
    await tearDownWeb(tester);
  });
}

/// Lets the real-time futures (in-memory DB, fake server) finish, then
/// rebuilds; repeated because each step starts the next one.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
}
