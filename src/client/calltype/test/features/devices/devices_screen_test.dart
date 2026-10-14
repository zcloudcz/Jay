import 'package:calltype/core/network/api_client.dart';
import 'package:calltype/core/network/signalr_client.dart';
import 'package:calltype/core/storage/database.dart';
import 'package:calltype/features/devices/device_service.dart';
import 'package:calltype/features/devices/devices_screen.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../helpers/fake_multi_device_server.dart';
import '../../helpers/localized_app.dart';
import '../../helpers/test_device.dart';

const phoneId = 'a0000000-0000-4000-8000-000000000001';
const webId = 'a0000000-0000-4000-8000-000000000002';

void main() {
  late FakeMultiDeviceServer server;
  late TestDevice phone;
  late TestDevice web;

  Future<void> pump(WidgetTester tester, TestDevice device, DeviceService devices) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<AppDatabase>.value(value: device.db),
          Provider<ApiClient>.value(value: FakeDeviceApi(server)),
          ChangeNotifierProvider<SignalRClient>.value(value: server.hubs[device.id]!),
          ChangeNotifierProvider<DeviceService>.value(value: devices),
        ],
        child: localizedApp(home: const DevicesScreen()),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
  }

  Future<void> setUpDevices(WidgetTester tester) async {
    await tester.runAsync(() async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      server = FakeMultiDeviceServer();
      phone = await TestDevice.create(phoneId);
      web = await TestDevice.create(webId);
      server
        ..add(phone)
        ..add(web);
      await server.link(phone, [web], version: 1);
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

  testWidgets('the primary lists its companion and can link another', (tester) async {
    await setUpDevices(tester);
    final devices = (await tester.runAsync(() async {
      final service = await server.deviceServiceFor(phone);
      await service.checkOwnList(phoneId);
      return service;
    }))!;
    await pump(tester, phone, devices);

    expect(find.text(l10nEn.devicesDeviceLabel(webId.substring(0, 8))), findsOneWidget);
    expect(find.text(l10nEn.devicesRemove), findsOneWidget);
    expect(find.text(l10nEn.devicesAdd), findsOneWidget);
    // A primary with a companion is not an empty device.
    expect(find.text(l10nEn.linkDeviceAction), findsNothing);
    await tearDownDevices(tester);
  });

  testWidgets('a vanished companion is asked about, and Keep dismisses the prompt', (tester) async {
    await setUpDevices(tester);
    final devices = (await tester.runAsync(() async {
      final service = await server.deviceServiceFor(phone);
      await service.checkOwnList(phoneId);
      await service.reportVanishedCompanions([webId]);
      return service;
    }))!;
    await pump(tester, phone, devices);

    final prompt = l10nEn.devicesVanishedPrompt(
      l10nEn.devicesDeviceLabel(webId.substring(0, 8)),
    );
    expect(find.text(prompt), findsOneWidget);
    expect(find.text(l10nEn.devicesKeep), findsOneWidget);

    await tester.tap(find.text(l10nEn.devicesKeep));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    expect(find.text(prompt), findsNothing);
    expect(devices.vanishedCompanions, isEmpty);
    // Keep changes nothing in the list.
    expect(find.text(l10nEn.devicesDeviceLabel(webId.substring(0, 8))), findsOneWidget);
    await tearDownDevices(tester);
  });

  testWidgets('a companion only says whose device it is', (tester) async {
    await setUpDevices(tester);
    final devices = (await tester.runAsync(() async {
      await web.db
          .into(web.db.backupState)
          .insert(
            BackupStateCompanion.insert(
              key: linkedPrimaryHandleKey,
              value: 'CT-PHON-E001',
            ),
          );
      final service = await server.deviceServiceFor(web);
      service.expectLink(phoneId);
      await service.checkOwnList(phoneId);
      return service;
    }))!;
    await pump(tester, web, devices);

    expect(find.text(l10nEn.devicesLinkedTo('CT-PHON-E001')), findsOneWidget);
    expect(find.text(l10nEn.devicesAdd), findsNothing);
    await tearDownDevices(tester);
  });
}
