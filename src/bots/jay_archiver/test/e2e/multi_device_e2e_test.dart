// Live proof of multi-device fan-out: real crypto, real hub, real API.
// Skipped without JAY_E2E_API. LOCAL compose only, never beta or production.
@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:test/test.dart';

import 'e2e_device.dart';

void main() {
  final baseUrl = Platform.environment['JAY_E2E_API'];

  test(
    'messages reach every device of an identity, in the same conversation',
    skip: baseUrl == null ? 'set JAY_E2E_API to a LOCAL API' : null,
    () async {
      final aPhone = await E2eDevice.register(baseUrl!);
      final aWeb = await E2eDevice.register(baseUrl);
      final b = await E2eDevice.register(baseUrl);
      addTearDown(() => Future.wait([aPhone, aWeb, b].map((d) => d.close())));
      await Future.wait([aPhone, aWeb, b].map((d) => d.signalR.connect()));

      // A links the web device. The companion pins its primary by starting a
      // session with it, then verifies the list it is in.
      await aPhone.setCompanions([aWeb], version: 1);
      await aPhone.directory.refresh(aPhone.id, ensurePinned: aPhone.ensureSession);
      await aWeb.directory.refresh(aWeb.id, ensurePinned: aWeb.ensureSession);
      expect(aWeb.directory.isCompanion, isTrue);
      expect(aWeb.directory.selfIdentityId, aPhone.id);

      // 1. B -> A arrives on BOTH of A's devices.
      var onPhone = aPhone.nextMessage();
      var onWeb = aWeb.nextMessage();
      await b.sendDirect(aPhone.id, 'hello both');
      for (final received in [await onPhone, await onWeb]) {
        expect(received.body, 'hello both');
        expect(received.route.conversationId, b.id);
        expect(received.route.own, isFalse);
      }

      // 2. A's WEB device answers: B sees it in the conversation with A's
      //    identity, and A's phone gets a copy marked as its own.
      final atB = b.nextMessage();
      onPhone = aPhone.nextMessage();
      await aWeb.sendDirect(b.id, 'from the web');
      final seenByB = await atB;
      expect(seenByB.body, 'from the web');
      expect(seenByB.route.conversationId, aPhone.id);
      expect(seenByB.route.senderIdentityId, aPhone.id);
      final copy = await onPhone;
      expect(copy.body, 'from the web');
      expect(copy.route.own, isTrue);
      expect(copy.route.conversationId, b.id);

      // 3. A removes the web device. B still has version 1 stored and does
      //    not re-read it before sending; the hub answers device_list_stale
      //    with A's remaining devices and B's retry (reconcile) drops the
      //    removed one.
      await aPhone.setCompanions([], version: 2);
      onPhone = aPhone.nextMessage();
      var leaked = false;
      final webSub = aWeb.signalR.onMessage.listen((_) => leaked = true);
      addTearDown(webSub.cancel);
      await b.sendDirect(aPhone.id, 'phone only');
      expect((await onPhone).body, 'phone only');
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(leaked, isFalse);
      // The stale answer made B re-read A's list: the removal now holds on
      // B's side too, not only on the (honest) server.
      expect(await b.directory.devicesOf(aPhone.id), [aPhone.id]);
    },
  );
}
