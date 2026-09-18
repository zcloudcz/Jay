// Shared by the live E2E tests in this folder: a real registered device with
// real calltype_core crypto, REST and hub — no UI, the same path bots take.
import 'dart:convert';
import 'dart:math';

import 'package:calltype_bot/calltype_bot.dart' show WebSocketHubTransport;
import 'package:calltype_core/auth/auth_service.dart';
import 'package:calltype_core/crypto/group_cipher.dart';
import 'package:calltype_core/crypto/key_manager.dart';
import 'package:calltype_core/crypto/session_manager.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/network/signalr_client.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:calltype_core/storage/secret_store.dart';
import 'package:drift/native.dart';

class MemoryStore extends SecretStore {
  final _values = <String, String>{};
  @override
  Future<String?> read(String key) async => _values[key];
  @override
  Future<void> write(String key, String value) async => _values[key] = value;
  @override
  Future<void> delete(String key) async => _values.remove(key);
}

final random = Random.secure();

/// RFC 4122 v4 — the hub parses message ids as GUIDs.
String uuid() {
  final b = List<int>.generate(16, (_) => random.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

/// One registered device with everything the app has: keys, sessions, REST
/// and hub. State lives in memory — each run is a set of brand-new identities.
class E2eDevice {
  E2eDevice._(this.id, this.api, this.sessions, this.signalR, this._db);

  final String id;
  final ApiClient api;
  final SessionManager sessions;
  final SignalRClient signalR;
  final AppDatabase _db;

  static Future<E2eDevice> register(String baseUrl, {bool isBot = false}) async {
    final store = MemoryStore();
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

    return E2eDevice._(
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
    final messageId = uuid();
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

  /// H1: sends a "call-event" group message — the ordinary E2E message a
  /// client sends into a business conversation when a call ends, fanned out
  /// like `sendToGroup` but with a typed body instead of free text.
  Future<String> sendCallEvent(
    String groupId,
    List<String> recipients,
    Map<String, dynamic> details,
  ) async {
    final messageId = uuid();
    final payload = jsonEncode({
      'v': 1,
      'id': messageId,
      'body': jsonEncode(details),
      'type': 'call-event',
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

  /// Organizations belong to accounts: registers one and links this device.
  Future<void> linkNewAccount() async {
    final authKey = base64Encode(List.generate(32, (_) => random.nextInt(256)));
    final account = await api.registerAccount(
      email: 'e2e-${uuid()}@example.test',
      authKey: authKey,
    );
    await api.transport.post<void>(
      '/accounts/${account['accountId']}/devices/$id',
      data: {'authKey': authKey},
    );
  }
}
