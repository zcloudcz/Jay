// End-to-end check of the E07 emergency channel against a REAL server: a kit
// of one-time codes, a device with NO account and NO prior enrollment joining
// with one of them, a reachability drill over the real hub, and the proof
// export — all through the same calltype_core client code the app uses.
//
// Skipped unless JAY_E2E_API is set (local docker-compose:
// http://localhost:8080). NEVER point this at beta/production: the audit
// database is append-only, every run leaves an undeletable organization.
//
// The server allows 10 "auth" calls per minute per IP (token, device link,
// emergency enroll). Both E2E files together use exactly 10, which is why
// this test is frugal with devices — and why a re-run within the same minute
// fails with 429.
@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:calltype_core/network/emergency_api.dart';
import 'package:calltype_core/network/emergency_dtos.dart';
import 'package:calltype_core/network/organization_api.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

import 'e2e_device.dart';

/// A rejected emergency code: HTTP 410 carrying the given machine-readable code.
Matcher _gone(String code) => throwsA(
  isA<DioException>()
      .having((e) => e.response?.statusCode, 'status', 410)
      .having(emergencyErrorCode, 'code', code),
);

void main() {
  final baseUrl = Platform.environment['JAY_E2E_API'];

  test(
    'emergency kit: offline code enrolls a bare device, drill reaches it, codes die',
    skip: baseUrl == null
        ? 'set JAY_E2E_API to a LOCAL API with Business mode on'
        : null,
    () async {
      final owner = await E2eDevice.register(baseUrl!);
      final auditor = await E2eDevice.register(baseUrl, isBot: true);
      // The whole point of E07: no account, never invited — a printed code
      // is all this device holds.
      final responder = await E2eDevice.register(baseUrl);
      addTearDown(() => Future.wait([owner, auditor, responder].map((d) => d.close())));

      await owner.linkNewAccount();
      final orgId = (await owner.api.createOrganization(
        'E2E emergency ${DateTime.now().toIso8601String()}',
      )).organizationId;

      // The emergency group is a business group, so it needs the auditor first.
      await expectLater(
        owner.api.issueEmergencyKit(orgId, label: 'too early', count: 1),
        throwsA(
          isA<DioException>()
              .having((e) => e.response?.statusCode, 'status', 409)
              .having(emergencyErrorCode, 'code', EmergencyErrorCodes.auditorNotConfigured),
        ),
      );
      await owner.api.setAuditorDevice(orgId, auditor.id);

      // W2-F fail-closed: `auditor` is registered above but its SignalR
      // connection is never started for the rest of this test — its "alive"
      // check (MessengerHub presence + backlog) would read as dead
      // throughout. The emergency kit issue, enroll, drill and proof calls
      // below all succeed anyway, because EmergencyGroupService/the emergency
      // hub event path are deliberately NOT gated by W2-F (the emergency
      // group exists for exactly the moment the auditor/infrastructure is
      // unavailable — see docs/superpowers/plans/2026-09-18-business-mode-contracts.md
      // §W2-F). This test's continued success IS the fail-open assertion.
      final kit = await owner.api.issueEmergencyKit(orgId, label: 'HQ incident team', count: 2);
      expect(kit.codes, hasLength(2));
      expect(kit.codes.toSet(), hasLength(2), reason: 'codes must be distinct');

      // Enrollment with nothing but the code.
      expect(await responder.api.enrollWithEmergencyCode(kit.codes[0]), orgId);

      // One-time means one-time, also for a different device.
      await expectLater(
        owner.api.enrollWithEmergencyCode(kit.codes[0]),
        _gone(EmergencyErrorCodes.emergencyCodeUsed),
      );

      var kits = await owner.api.getEmergencyKits(orgId);
      expect(kits.single.codesTotal, 2);
      expect(kits.single.codesRemaining, 1);

      // Drill: the enrolled device is reached over the hub and confirms.
      await responder.signalR.connect();
      final prompt = responder.signalR.onEmergencyDrill.first;
      final drillId = await owner.api.startEmergencyDrill(orgId);
      final event = await prompt.timeout(const Duration(seconds: 20));
      expect(event['organizationId'], orgId);
      expect(event['drillId'], drillId);

      await responder.api.confirmEmergencyDrill(orgId, drillId);
      await owner.api.completeEmergencyDrill(orgId, drillId);

      final drill = (await owner.api.getEmergencyDrills(orgId)).single;
      expect(drill.drillId, drillId);
      expect(drill.completedAt, isNotNull);
      expect(drill.confirmedMemberCount, 1);
      expect(drill.responseTimeSeconds, isNotNull);

      // Revoking the kit kills the code that is still unused.
      await owner.api.revokeEmergencyKit(orgId, kit.kitId);
      await expectLater(
        owner.api.enrollWithEmergencyCode(kit.codes[1]),
        _gone(EmergencyErrorCodes.kitRevoked),
      );
      kits = await owner.api.getEmergencyKits(orgId);
      expect(kits.single.revokedAt, isNotNull);

      // The proof an auditor/insurer gets: counts and the auditor, never a
      // code. kitsIssued == 1 also proves the rejected "too early" attempt
      // left nothing behind in the append-only database.
      final proof = utf8.decode(await owner.api.exportEmergencyProof(orgId, format: 'json'));
      final facts = jsonDecode(proof) as Map<String, dynamic>;
      expect(facts['emergencyGroupExists'], isTrue);
      expect(facts['auditorDeviceId'], auditor.id);
      expect(facts['kitsIssued'], 1);
      for (final secret in [...kit.codes, kit.recoveryCode]) {
        expect(proof, isNot(contains(secret)));
      }
    },
  );
}
