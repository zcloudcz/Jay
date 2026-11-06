import 'package:calltype/core/crypto/key_manager.dart';
import 'package:calltype/core/network/api_client.dart';
import 'package:calltype/core/network/signalr_client.dart';
import 'package:calltype/core/storage/database.dart';
import 'package:calltype/core/storage/secure_storage.dart';
import 'package:calltype/features/devices/device_service.dart';
import 'package:calltype/features/devices/devices_screen.dart';
import 'package:calltype/features/devices/link_controllers.dart';
import 'package:calltype/features/devices/link_device_screen.dart';
import 'package:calltype/features/devices/link_ux.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../helpers/fake_multi_device_server.dart';
import '../../helpers/localized_app.dart';
import '../../helpers/test_device.dart';

const phoneId = 'a0000000-0000-4000-8000-000000000001';
const webId = 'a0000000-0000-4000-8000-000000000002';
const bobId = 'b0000000-0000-4000-8000-000000000001';

/// Link UX A2 (the phone's "Link web / computer" entry) and A3 ("disconnect
/// this device and link it with your phone").
void main() {
  late FakeMultiDeviceServer server;
  late TestDevice phone;
  late TestDevice web;

  Future<void> setUpDevices(WidgetTester tester, {bool linked = false}) async {
    await tester.runAsync(() async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      server = FakeMultiDeviceServer();
      phone = await TestDevice.create(phoneId);
      web = await TestDevice.create(webId);
      server
        ..add(phone)
        ..add(web);
      if (linked) await server.link(phone, [web], version: 1);
    });
  }

  Future<void> tearDownDevices(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await server.close();
      await phone.close();
      await web.close();
    });
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
  }

  /// A device that already has a contact and a chat with Bob.
  Future<void> addData(TestDevice device) async {
    await device.db
        .into(device.db.contacts)
        .insert(
          ContactsCompanion.insert(
            deviceId: bobId,
            userHandle: 'CT-BOBB-0001',
            identityKey: Uint8List(32),
            addedAt: DateTime.now(),
          ),
        );
    await device.db
        .into(device.db.conversations)
        .insert(ConversationsCompanion.insert(id: bobId, type: 'direct'));
  }

  Future<int> rows(TestDevice device) async =>
      (await device.db.select(device.db.contacts).get()).length +
      (await device.db.select(device.db.conversations).get()).length;

  Widget providers(TestDevice device, DeviceService devices, Widget child) =>
      MultiProvider(
        providers: [
          Provider<AppDatabase>.value(value: device.db),
          Provider<ApiClient>.value(value: FakeDeviceApi(server)),
          Provider<KeyManager>.value(value: device.keys),
          Provider<SecureStorage>.value(value: device.secureStorage),
          ChangeNotifierProvider<SignalRClient>.value(
            value: server.hubs[device.id]!,
          ),
          ChangeNotifierProvider<DeviceService>.value(value: devices),
        ],
        child: child,
      );

  group('A2: Link web / computer entry', () {
    Future<void> pumpEntry(
      WidgetTester tester,
      TestDevice device,
      DeviceService devices, {
      required bool canScan,
    }) async {
      await tester.pumpWidget(
        providers(
          device,
          devices,
          localizedApp(
            home: Scaffold(
              appBar: AppBar(actions: [LinkWebButton(canScan: canScan)]),
              body: LinkWebTile(canScan: canScan),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('shown on the phone (primary) that can scan', (tester) async {
      await setUpDevices(tester);
      final devices = (await tester.runAsync(
        () => server.deviceServiceFor(phone),
      ))!;
      await pumpEntry(tester, phone, devices, canScan: true);

      expect(find.byTooltip(l10nEn.linkWebAction), findsOneWidget);
      expect(find.text(l10nEn.linkWebAction), findsOneWidget); // the tile
      await tearDownDevices(tester);
    });

    testWidgets('hidden where nothing can scan (desktop without camera)', (
      tester,
    ) async {
      await setUpDevices(tester);
      final devices = (await tester.runAsync(
        () => server.deviceServiceFor(phone),
      ))!;
      await pumpEntry(tester, phone, devices, canScan: false);

      expect(find.byTooltip(l10nEn.linkWebAction), findsNothing);
      expect(find.text(l10nEn.linkWebAction), findsNothing);
      await tearDownDevices(tester);
    });

    testWidgets('hidden on a companion, which cannot sign the list', (
      tester,
    ) async {
      await setUpDevices(tester, linked: true);
      final devices = (await tester.runAsync(() async {
        final service = await server.deviceServiceFor(web);
        service.expectLink(phoneId);
        await service.checkOwnList(phoneId);
        return service;
      }))!;
      expect(devices.isCompanion, isTrue);
      await pumpEntry(tester, web, devices, canScan: true);

      expect(find.byTooltip(l10nEn.linkWebAction), findsNothing);
      expect(find.text(l10nEn.linkWebAction), findsNothing);
      await tearDownDevices(tester);
    });
  });

  group('A3: disconnect this device and link it with your phone', () {
    Future<(DeviceService, GoRouter)> pumpDevicesScreen(
      WidgetTester tester,
    ) async {
      final devices = (await tester.runAsync(() async {
        await addData(web);
        return server.deviceServiceFor(web);
      }))!;
      final router = GoRouter(
        initialLocation: '/settings/devices',
        routes: [
          GoRoute(
            path: '/settings/devices',
            builder: (_, _) => const DevicesScreen(),
          ),
          GoRoute(
            path: '/onboarding',
            builder: (_, _) => const Scaffold(body: Placeholder()),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        providers(web, devices, localizedApp(router: router)),
      );
      await settle(tester);
      return (devices, router);
    }

    testWidgets('cancel deletes nothing', (tester) async {
      await setUpDevices(tester);
      await pumpDevicesScreen(tester);

      // A device with chats is not offered the plain "link" any more...
      expect(find.text(l10nEn.linkDeviceAction), findsNothing);
      await tester.tap(find.text(l10nEn.disconnectAndLinkAction));
      await settle(tester);
      // ...but the warning that says what is lost.
      expect(find.text(l10nEn.disconnectAndLinkWarning), findsOneWidget);
      expect(find.text(l10nEn.disconnectAndLinkBackup), findsOneWidget);

      await tester.tap(find.text(l10nEn.commonCancel));
      await settle(tester);

      expect(find.text(l10nEn.disconnectAndLinkWarning), findsNothing);
      expect(await tester.runAsync(() => rows(web)), 2);
      expect(
        await tester.runAsync(() => web.secureStorage.read(linkPendingKey)),
        isNull,
      );
      await tearDownDevices(tester);
    });

    testWidgets('confirm wipes the device and shows the link screen', (
      tester,
    ) async {
      await setUpDevices(tester);
      final (devices, router) = await pumpDevicesScreen(tester);

      await tester.tap(find.text(l10nEn.disconnectAndLinkAction));
      await settle(tester);
      await tester.tap(find.text(l10nEn.disconnectAndLinkConfirm));
      await settle(tester);

      expect(await tester.runAsync(() => rows(web)), 0);
      expect(await tester.runAsync(() => isEmptyDevice(web.db)), isTrue);
      expect(
        await tester.runAsync(() => web.secureStorage.read(linkPendingKey)),
        '1',
      );
      expect(
        router.routerDelegate.currentConfiguration.uri.toString(),
        linkFirstRoute,
      );
      // Keys and registration stay: the link code carries this device id.
      expect(devices.directory.selfDeviceId, webId);
      await tearDownDevices(tester);
    });

    testWidgets('the not-empty link screen resets and then shows the code', (
      tester,
    ) async {
      await setUpDevices(tester);
      final devices = (await tester.runAsync(() async {
        await addData(web);
        return server.deviceServiceFor(web);
      }))!;
      final controller = CompanionLinkController(
        database: web.db,
        devices: devices,
        keyManager: web.keys,
        signalRClient: server.hubs[webId]!,
      );
      await tester.runAsync(controller.start);
      expect(controller.state, CompanionLinkState.notEmpty);
      await tester.pumpWidget(
        providers(
          web,
          devices,
          ChangeNotifierProvider.value(
            value: controller,
            child: localizedApp(home: const LinkDeviceScreen()),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text(l10nEn.disconnectAndLinkAction));
      await settle(tester);
      await tester.tap(find.text(l10nEn.disconnectAndLinkConfirm));
      await settle(tester);

      expect(controller.state, CompanionLinkState.showingCode);
      expect(find.byType(QrImageView), findsOneWidget);
      expect(await tester.runAsync(() => rows(web)), 0);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await tearDownDevices(tester);
    });

    testWidgets('a primary with companions is refused and keeps its data', (
      tester,
    ) async {
      await setUpDevices(tester, linked: true);
      final devices = (await tester.runAsync(() async {
        await addData(phone);
        final service = await server.deviceServiceFor(phone);
        await service.checkOwnList(phoneId);
        return service;
      }))!;
      bool? result;
      await tester.pumpWidget(
        providers(
          phone,
          devices,
          localizedApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async =>
                      result = await confirmDisconnectAndLink(context),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await settle(tester);

      expect(find.text(l10nEn.disconnectAndLinkRefused), findsOneWidget);
      // Refused before asking: there is nothing to confirm.
      expect(find.text(l10nEn.disconnectAndLinkConfirm), findsNothing);
      await tester.tap(find.text('OK'));
      await settle(tester);
      expect(result, isFalse);
      expect(await tester.runAsync(() => rows(phone)), 2);
      final error = await tester.runAsync(() async {
        try {
          await devices.resetForLinking();
          return null;
        } catch (e) {
          return e;
        }
      });
      expect(error, isA<LinkResetRefused>());
      await tearDownDevices(tester);
    });
  });
}
