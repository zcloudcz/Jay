import 'package:calltype_core/storage/database.dart';
import 'package:calltype/features/devices/device_service.dart';
import 'package:calltype/features/devices/link_code.dart';
import 'package:calltype/features/devices/link_controllers.dart';
import 'package:calltype_core/crypto/device_list.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_multi_device_server.dart';
import '../../helpers/test_device.dart';

const phoneId = 'a0000000-0000-4000-8000-000000000001';
const webId = 'a0000000-0000-4000-8000-000000000002';
const bobId = 'b0000000-0000-4000-8000-000000000001';

void main() {
  late FakeMultiDeviceServer server;
  late TestDevice phone;
  late TestDevice web;
  late TestDevice bob;

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    server = FakeMultiDeviceServer();
    phone = await TestDevice.create(phoneId);
    web = await TestDevice.create(webId);
    bob = await TestDevice.create(bobId);
    for (final d in [phone, web, bob]) {
      server.add(d);
    }
  });

  tearDown(() async {
    await server.close();
    for (final d in [phone, web, bob]) {
      await d.close();
    }
  });

  Future<String> codeOf(TestDevice device, {TestDevice? keysOf}) async {
    final bundle = await (keysOf ?? device).keys.getSignedIdentityBundle();
    return LinkCode(
      device.id,
      linkFingerprint(bundle['identityKey']!, bundle['signingKey']!),
    ).toString();
  }

  Future<String> consentOf(TestDevice device, String primary) async =>
      signDeviceLinkConsent(
        companionSigningKey: await device.keys.getSigningKeyPair(),
        primaryDeviceId: primary,
        companionDeviceId: device.id,
      );

  group('primary', () {
    test('offers only after the fingerprint matched, then signs the consented device in', () async {
      final devices = await server.deviceServiceFor(phone);
      final hub = server.hubs[phoneId]!;
      final controller = PrimaryLinkController(
        devices: devices,
        apiClient: FakeDeviceApi(server),
        signalRClient: hub,
      );
      addTearDown(controller.dispose);

      final linking = controller.link(await codeOf(web));
      await until(() => hub.sentOffers.isNotEmpty);
      expect(hub.sentOffers, [webId]);
      expect(controller.state, PrimaryLinkState.waitingForConsent);
      // The real hub records the consent before it relays it, and the PUT
      // demands that record; the fake needs the same record set by the test.
      server.recordConsent(webId, phoneId);
      hub.consents.add({'deviceId': webId, 'consentSig': await consentOf(web, phoneId)});
      await linking;

      expect(controller.state, PrimaryLinkState.linked);
      expect((await devices.companions()).single.deviceId, webId);
      expect(await devices.directory.devicesOf(phoneId), [phoneId, webId]);
    });

    test('a code whose keys differ from the served bundle is refused before any offer', () async {
      final devices = await server.deviceServiceFor(phone);
      final hub = server.hubs[phoneId]!;
      final controller = PrimaryLinkController(
        devices: devices,
        apiClient: FakeDeviceApi(server),
        signalRClient: hub,
      );
      addTearDown(controller.dispose);

      await controller.link(await codeOf(web, keysOf: bob));

      expect(controller.state, PrimaryLinkState.mismatch);
      expect(hub.sentOffers, isEmpty);
      expect(server.lists, isEmpty);
    });

    test('a consent signed for another primary is refused', () async {
      final devices = await server.deviceServiceFor(phone);
      final hub = server.hubs[phoneId]!;
      final controller = PrimaryLinkController(
        devices: devices,
        apiClient: FakeDeviceApi(server),
        signalRClient: hub,
      );
      addTearDown(controller.dispose);

      final linking = controller.link(await codeOf(web));
      await until(() => hub.sentOffers.isNotEmpty);
      hub.consents.add({'deviceId': webId, 'consentSig': await consentOf(web, bobId)});
      await linking;

      expect(controller.state, PrimaryLinkState.failed);
      expect(server.lists, isEmpty);
    });
    test('closing the dialog cancels: a later consent signs nothing', () async {
      final devices = await server.deviceServiceFor(phone);
      final hub = server.hubs[phoneId]!;
      final controller = PrimaryLinkController(
        devices: devices,
        apiClient: FakeDeviceApi(server),
        signalRClient: hub,
      );
      addTearDown(controller.dispose);

      final linking = controller.link(await codeOf(web));
      await until(() => hub.sentOffers.isNotEmpty);
      controller.cancel();
      server.recordConsent(webId, phoneId);
      hub.consents.add({'deviceId': webId, 'consentSig': await consentOf(web, phoneId)});
      await linking;

      expect(server.lists, isEmpty);
      expect(controller.state, isNot(PrimaryLinkState.linked));
    });
  });

  group('new device', () {
    test('shows its code, confirms the offered handle, consents and ends linked', () async {
      final devices = await server.deviceServiceFor(web);
      final hub = server.hubs[webId]!;
      final controller = CompanionLinkController(
        database: web.db,
        devices: devices,
        keyManager: web.keys,
        signalRClient: hub,
      );
      addTearDown(controller.dispose);

      await controller.start();
      expect(controller.state, CompanionLinkState.showingCode);
      expect(controller.code, await codeOf(web));

      hub.offers.add({'primaryDeviceId': phoneId, 'userHandle': 'CT-PHON-E001'});
      await until(() => controller.state == CompanionLinkState.offered);
      expect(controller.offeredHandle, 'CT-PHON-E001');

      await controller.accept();
      final (primary, consentSig) = hub.sentConsents.single;
      expect(primary, phoneId);
      final bundle = await web.keys.getSignedIdentityBundle();
      expect(
        await verifyDeviceLinkConsent(
          consentSig: consentSig,
          companionSigningKey: bundle['signingKey']!,
          primaryDeviceId: phoneId,
          companionDeviceId: webId,
        ),
        isTrue,
      );

      // The primary signs and uploads; the hub sends the hint.
      await server.link(phone, [web], version: 1);
      hub.listChanged.add({'primaryDeviceId': phoneId, 'version': 1});
      await until(() => controller.state == CompanionLinkState.linked);
      expect(devices.directory.selfIdentityId, phoneId);
      expect(await devices.linkedPrimaryHandle(), 'CT-PHON-E001');
    });

    test('a device with chats cannot be linked', () async {
      await web.db
          .into(web.db.conversations)
          .insert(ConversationsCompanion.insert(id: bobId, type: 'direct'));
      final devices = await server.deviceServiceFor(web);
      final controller = CompanionLinkController(
        database: web.db,
        devices: devices,
        keyManager: web.keys,
        signalRClient: server.hubs[webId]!,
      );
      addTearDown(controller.dispose);

      await controller.start();

      expect(controller.state, CompanionLinkState.notEmpty);
      expect(controller.code, isNull);
    });
    test('cancel in waiting returns to the code and ignores the primary afterwards', () async {
      final devices = await server.deviceServiceFor(web);
      final hub = server.hubs[webId]!;
      final controller = CompanionLinkController(
        database: web.db,
        devices: devices,
        keyManager: web.keys,
        signalRClient: hub,
      );
      addTearDown(controller.dispose);
      await controller.start();
      hub.offers.add({'primaryDeviceId': phoneId, 'userHandle': 'CT-PHON-E001'});
      await until(() => controller.state == CompanionLinkState.offered);
      await controller.accept();
      expect(controller.state, CompanionLinkState.waiting);

      controller.reject();
      expect(controller.state, CompanionLinkState.showingCode);

      // The primary finishes anyway: the hint must not link a cancelled device.
      await server.link(phone, [web], version: 1);
      hub.listChanged.add({'primaryDeviceId': phoneId, 'version': 1});
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(devices.isCompanion, isFalse);
      expect(controller.state, CompanionLinkState.showingCode);
    });

    test('waiting times out into the failed state, and retry shows the code', () async {
      final devices = await server.deviceServiceFor(web);
      final hub = server.hubs[webId]!;
      final controller = CompanionLinkController(
        database: web.db,
        devices: devices,
        keyManager: web.keys,
        signalRClient: hub,
        waitTimeout: const Duration(milliseconds: 50),
      );
      addTearDown(controller.dispose);
      await controller.start();
      hub.offers.add({'primaryDeviceId': phoneId, 'userHandle': 'CT-PHON-E001'});
      await until(() => controller.state == CompanionLinkState.offered);
      await controller.accept();

      await until(() => controller.state == CompanionLinkState.failed);
      controller.reject();
      expect(controller.state, CompanionLinkState.showingCode);
    });

    test('a device that is not registered yet fails instead of spinning', () async {
      final unopened = DeviceService(
        database: web.db,
        apiClient: FakeDeviceApi(server),
        keyManager: web.keys,
        sessionManager: web.sessions,
        signalRClient: FakeHubClient(server, webId),
      );
      addTearDown(unopened.dispose);
      final controller = CompanionLinkController(
        database: web.db,
        devices: unopened,
        keyManager: web.keys,
        signalRClient: FakeHubClient(server, webId),
      );
      addTearDown(controller.dispose);

      await controller.start();

      expect(controller.state, CompanionLinkState.failed);
      controller.reject();
      expect(controller.state, CompanionLinkState.failed);
    });

    test('confirming one vanished companion removes only that one', () async {
      final extra = await TestDevice.create('a0000000-0000-4000-8000-000000000003');
      addTearDown(extra.close);
      server.add(extra);
      await server.link(phone, [web, extra], version: 1);
      final devices = await server.deviceServiceFor(phone);
      await devices.checkOwnList(phoneId);
      await devices.reportVanishedCompanions([webId, extra.id]);

      await devices.confirmRemoveVanished(ids: [webId]);

      expect((await devices.companions()).map((d) => d.deviceId), [extra.id]);
      expect(devices.vanishedCompanions, {extra.id});
    });
  });
}
