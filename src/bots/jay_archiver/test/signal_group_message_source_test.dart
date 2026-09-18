import 'dart:convert';

import 'package:calltype_core/crypto/key_manager.dart';
import 'package:calltype_core/crypto/session_manager.dart';
import 'package:calltype_core/network/signalr_client.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:calltype_core/storage/secret_store.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/native.dart';
import 'package:jay_archiver/jay_archiver.dart';
import 'package:test/test.dart';

import 'helpers.dart';

class _MemoryStore extends SecretStore {
  final _values = <String, String>{};
  @override
  Future<String?> read(String key) async => _values[key];
  @override
  Future<void> write(String key, String value) async => _values[key] = value;
  @override
  Future<void> delete(String key) async => _values.remove(key);
}

void main() {
  late FakeHub hub;
  late SignalRClient signalR;
  late SessionManager archiverSessions;
  late KeyManager archiverKeys;
  late FakeUser alice;
  late SignalGroupMessageSource source;
  final logs = <String>[];

  setUp(() async {
    hub = FakeHub();
    final db = AppDatabase(NativeDatabase.memory());
    archiverKeys = KeyManager(secureStorage: _MemoryStore());
    archiverSessions = SessionManager(database: db, keyManager: archiverKeys);
    signalR = SignalRClient(
      baseUrl: 'http://unused',
      deviceId: 'archiver',
      transportFactory: (_, _) => hub,
    );
    await signalR.connect();
    alice = await FakeUser.create('alice');
    logs.clear();
    source = SignalGroupMessageSource(
      signalR: signalR,
      sessions: archiverSessions,
      log: logs.add,
    );
  });

  tearDown(() async {
    signalR.close();
    await alice.close();
  });

  test('decrypts a text group message into archivable metadata', () async {
    const body = 'the secret plaintext marker';
    final data = await alice.messageTo(
      'archiver',
      {...await archiverKeys.getSignedIdentityBundle()},
      body,
      groupId: 'g1',
    );

    final events = source.messages;
    final first = events.first;
    hub.deliver(data);
    final event = await first;

    expect(event.groupId, 'g1');
    expect(event.senderId, 'alice');
    expect(event.kind, 'text');
    expect(event.sizeBytes, utf8.encode(body).length);
    expect(event.contentHashHex, crypto.sha256.convert(utf8.encode(body)).toString());
  });

  test('1:1 (non-group) messages are dropped: acked, never decrypted or emitted', () async {
    final data = await alice.messageTo(
      'archiver',
      {...await archiverKeys.getSignedIdentityBundle()},
      'hi',
      groupId: 'g1',
    )
      ..['groupId'] = null; // simulate a direct message

    var sawEvent = false;
    final sub = source.messages.listen((_) => sawEvent = true);
    hub.deliver(data);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await sub.cancel();

    expect(sawEvent, isFalse);
    // Acked so the server stops redelivering it — anyone can address a direct
    // message to the auditor's device id.
    expect(hub.calls('AcknowledgeMessage'), hasLength(1));
  });

  test('undecryptable messages are logged by id only, never emitted', () async {
    final garbage = {
      'senderId': 'alice',
      'messageId': 'bad-1',
      'groupId': 'g1',
      'encryptedBody': 'not-valid-base64-envelope!!',
    };

    var sawEvent = false;
    final sub = source.messages.listen((_) => sawEvent = true);
    hub.deliver(garbage);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await sub.cancel();

    expect(sawEvent, isFalse);
    expect(logs, hasLength(1));
    expect(logs.single, contains('bad-1'));
  });

  test('attachment sizeBytes reflects the decoded file, not the JSON envelope', () async {
    final fileBytes = List<int>.generate(1000, (i) => i % 256);
    final envelope = jsonEncode({'name': 'a.bin', 'data': base64Encode(fileBytes)});
    final data = await alice.messageTo(
      'archiver',
      {...await archiverKeys.getSignedIdentityBundle()},
      envelope,
      groupId: 'g1',
      type: 'file',
    );

    final first = source.messages.first;
    hub.deliver(data);
    final event = await first;

    expect(event.kind, 'attachment');
    expect(event.sizeBytes, fileBytes.length);
    expect(event.contentHashHex, crypto.sha256.convert(utf8.encode(envelope)).toString());
  });
}
