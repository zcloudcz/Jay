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
import 'dart:math';

import 'package:calltype_bot/calltype_bot.dart' show WebSocketHubTransport;
import 'package:calltype_core/auth/auth_service.dart';
import 'package:calltype_core/crypto/group_cipher.dart';
import 'package:calltype_core/crypto/key_manager.dart';
import 'package:calltype_core/crypto/session_manager.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/network/organization_api.dart';
import 'package:calltype_core/network/signalr_client.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:calltype_core/storage/secret_store.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:jay_archiver/jay_archiver.dart';
import 'package:test/test.dart';

class _MemoryStore extends SecretStore {
  final _values = <String, String>{};
  @override
  Future<String?> read(String key) async => _values[key];
  @override
  Future<void> write(String key, String value) async => _values[key] = value;
  @override
  Future<void> delete(String key) async => _values.remove(key);
}

final _random = Random.secure();

/// RFC 4122 v4 — the hub parses message ids as GUIDs.
String _uuid() {
  final b = List<int>.generate(16, (_) => _random.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

/// One registered device with everything the app has: keys, sessions, REST
/// and hub. State lives in memory — each run is a set of brand-new identities.
class _Device {
  _Device._(this.id, this.api, this.sessions, this.signalR, this._db);

  final String id;
  final ApiClient api;
  final SessionManager sessions;
  final SignalRClient signalR;
  final AppDatabase _db;

  static Future<_Device> register(String baseUrl, {bool isBot = false}) async {
    final store = _MemoryStore();
    final db = AppDatabase(NativeDatabase.memory());
    final keys = KeyManager(secureStorage: store);
    final auth = AuthService(secureStorage: store, baseUrl: baseUrl);
    final api = ApiClient(baseUrl: baseUrl, authService: auth);

    final bundle = await keys.getSignedIdentityBundle();
    final result = await api.registerDevice(
      identityKey: bundle['identityKey']!,
      signedPreKey: bundle['signedPreKey']!,
      signingKey: bundle['signingKey'],
      signature: bundle['signature'],
      oneTimePreKeys: [
        for (final preKey in await keys.getOrCreateOneTimePreKeys())
          {'keyId': preKey['keyId'], 'publicKey': preKey['publicKey']},
      ],
      isBot: isBot,
    );
    final id = result['deviceId'] as String;
    await store.setDeviceSecret(result['deviceSecret'] as String);
    await store.setDeviceId(id);

    return _Device._(
      id,
      api,
      SessionManager(database: db, keyManager: keys),
      SignalRClient(
        baseUrl: baseUrl,
        deviceId: id,
        authService: auth,
        transportFactory: WebSocketHubTransport.new,
      ),
      db,
    );
  }

  Future<void> _ensureSession(String peer) async {
    if (!await sessions.hasSession(peer)) {
      await sessions.initiateSession(peer, await api.getKeyBundle(peer));
    }
  }

  /// Per-recipient fan-out exactly like the app: ONE hub call carrying every
  /// recipient's ciphertext, which is what KB2 inspects for the auditor.
  Future<String> sendToGroup(
    String groupId,
    List<String> recipients,
    String text,
  ) async {
    final messageId = _uuid();
    final payload = jsonEncode({
      'v': 1,
      'id': messageId,
      'body': text,
      'type': 'text',
      'groupId': groupId,
      'groupName': null,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    });
    final encrypted = await GroupCipher(
      sessionManager: sessions,
      ensureSession: _ensureSession,
    ).encryptForGroup(groupId, recipients, payload);
    await signalR.sendGroupMessage(
      groupId,
      encrypted.map((id, bytes) => MapEntry(id, base64Encode(bytes))),
      messageId: messageId,
    );
    return messageId;
  }

  Future<void> close() async {
    signalR.close();
    await _db.close();
  }
}

void main() {
  final baseUrl = Platform.environment['JAY_E2E_API'];

  test(
    'business group: auditor is forced, archived, and cannot be removed',
    skip: baseUrl == null
        ? 'set JAY_E2E_API to a LOCAL API with Business mode on'
        : null,
    () async {
      final owner = await _Device.register(baseUrl!);
      final member = await _Device.register(baseUrl);
      final auditor = await _Device.register(baseUrl, isBot: true);
      addTearDown(() => Future.wait([owner, member, auditor].map((d) => d.close())));

      // Organizations belong to accounts, so the owner device needs one.
      final authKey = base64Encode(List.generate(32, (_) => _random.nextInt(256)));
      final account = await owner.api.registerAccount(
        email: 'e2e-${_uuid()}@example.test',
        authKey: authKey,
      );
      await owner.api.transport.post<void>(
        '/accounts/${account['accountId']}/devices/${owner.id}',
        data: {'authKey': authKey},
      );

      final org = await owner.api.createOrganization('E2E ${DateTime.now().toIso8601String()}');
      final orgId = org.organizationId;
      await owner.api.setAuditorDevice(orgId, auditor.id);

      // Invites are single-use, and the creator must be enrolled too.
      for (final device in [owner, member]) {
        final invite = await owner.api.createInvite(orgId);
        expect(await device.api.enrollWithInvite(invite.code), orgId);
      }

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

      // The real archiver, running as the auditor device.
      await Future.wait([owner, member, auditor].map((d) => d.signalR.connect()));
      final archiver = Archiver(
        source: SignalGroupMessageSource(signalR: auditor.signalR, sessions: auditor.sessions),
        api: auditor.api.transport,
        organizationId: orgId,
      );
      unawaited(archiver.run());
      addTearDown(archiver.stop);

      // KB2: a fan-out that skips the auditor is rejected before anything is
      // queued. The server checks recipients before decoding, so a dummy
      // ciphertext is enough — and no ratchet state is burned on a message
      // that never arrives.
      await expectLater(
        owner.signalR.sendGroupMessage(groupId, {member.id: 'AA=='}, messageId: _uuid()),
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
    },
  );
}
