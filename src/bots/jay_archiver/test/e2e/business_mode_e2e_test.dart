// End-to-end check of Business mode step 1 against a REAL server: three
// devices (owner, member, auditor) with real calltype_core crypto, the real
// hub and the real Archiver. No UI — this is the same path bots take.
//
// Skipped unless JAY_E2E_API is set, because it needs a running API with
// Business mode on (local docker-compose: http://localhost:8080).
//
// NEVER point this at beta/production: the audit database is append-only, so
// every run leaves an organization and records that cannot be deleted.
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:calltype_core/network/organization_api.dart';
import 'package:dio/dio.dart';
import 'package:jay_archiver/jay_archiver.dart';
import 'package:test/test.dart';

import 'e2e_device.dart';

void main() {
  final baseUrl = Platform.environment['JAY_E2E_API'];

  test(
    'business group: auditor is forced, archived, and cannot be removed',
    skip: baseUrl == null
        ? 'set JAY_E2E_API to a LOCAL API with Business mode on'
        : null,
    () async {
      final owner = await E2eDevice.register(baseUrl!);
      final member = await E2eDevice.register(baseUrl);
      final auditor = await E2eDevice.register(baseUrl, isBot: true);
      addTearDown(() => Future.wait([owner, member, auditor].map((d) => d.close())));

      await owner.linkNewAccount();

      final org = await owner.api.createOrganization('E2E ${DateTime.now().toIso8601String()}');
      final orgId = org.organizationId;
      await owner.api.setAuditorDevice(orgId, auditor.id);

      // Invites are single-use, and the creator must be enrolled too.
      for (final device in [owner, member]) {
        final invite = await owner.api.createInvite(orgId);
        expect(await device.api.enrollWithInvite(invite.code), orgId);
      }

      // The real archiver, running as the auditor device. (It does not have
      // to be connected for the group to be created or for messages to be
      // accepted — its copies would simply wait in the queue; business traffic
      // only stops once that queue has gone unprocessed for 24 h.)
      await Future.wait([owner, member, auditor].map((d) => d.signalR.connect()));
      final archiver = Archiver(
        source: SignalGroupMessageSource(signalR: auditor.signalR, sessions: auditor.sessions),
        api: auditor.api.transport,
        organizationId: orgId,
      );
      unawaited(archiver.run());
      addTearDown(archiver.stop);

      final group = await owner.api.createGroup('ignored', [member.id], organizationId: orgId);
      final groupId = group['groupId'] as String;

      // KB1: the server added the auditor, visibly, with its own role.
      final members = (await owner.api.transport.get<List<dynamic>>('/groups/$groupId/members')).data!;
      expect(
        members.where((m) => m['deviceId'] == auditor.id).map((m) => m['role']),
        ['auditor'],
      );

      // KB1: nobody can take the auditor out of the conversation.
      await expectLater(
        owner.api.transport.delete<void>('/groups/$groupId/members/${auditor.id}'),
        throwsA(
          isA<DioException>()
              .having((e) => e.response?.statusCode, 'status', 409)
              .having((e) => (e.response?.data as Map?)?['error'], 'error', 'auditor_immutable'),
        ),
      );

      // KB2: a fan-out that skips the auditor is rejected before anything is
      // queued. The server checks recipients before decoding, so a dummy
      // ciphertext is enough — and no ratchet state is burned on a message
      // that never arrives.
      await expectLater(
        owner.signalR.sendGroupMessage(groupId, {member.id: 'AA=='}, messageId: uuid()),
        throwsA(predicate((e) => '$e'.contains('audit_recipient_missing'))),
      );
      expect(await owner.api.getAuditRecordCount(orgId), 0);

      // Happy path: the member reads it AND the archive gets exactly one record.
      final received = member.signalR.onMessage.first;
      const text = 'quarterly numbers attached';
      final messageId = await owner.sendToGroup(groupId, [member.id, auditor.id], text);

      final envelope = await received.timeout(const Duration(seconds: 20));
      expect(envelope['messageId'], messageId);
      final plaintext = await member.sessions.decryptMessage(
        owner.id,
        utf8.decode(base64Decode(envelope['encryptedBody'] as String)),
      );
      expect((jsonDecode(plaintext) as Map)['body'], text);

      var count = 0;
      for (var i = 0; i < 40 && count == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        count = await owner.api.getAuditRecordCount(orgId);
      }
      expect(count, 1, reason: 'the archiver should have written one metadata record');

      // H1: a business call offer is logged BEFORE the callee answers
      // (businessGroupId travels on the relayed signal), and the call-event
      // both sides send afterward archives as a readable call-metadata record.
      final signalReceived = member.signalR.onCallSignal.first;
      await owner.signalR.sendCallSignal(
        member.id,
        'offer',
        '{"sdp":"dummy"}',
        businessGroupId: groupId,
      );
      final signal = await signalReceived.timeout(const Duration(seconds: 20));
      expect(signal['businessGroupId'], groupId);

      final callId = uuid();
      final startedAt = DateTime.now().toUtc();
      final endedAt = startedAt.add(const Duration(minutes: 3));
      await owner.sendCallEvent(groupId, [member.id, auditor.id], {
        'callId': callId,
        'role': 'caller',
        'peerDeviceId': member.id,
        'startedAt': startedAt.toIso8601String(),
        'endedAt': endedAt.toIso8601String(),
        'media': 'audio',
        'outcome': 'completed',
      });

      var callCount = 0;
      for (var i = 0; i < 40 && callCount < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        callCount = await owner.api.getAuditRecordCount(orgId);
      }
      expect(callCount, 2, reason: 'the archive should now also hold the call-metadata record');
    },
  );
}
