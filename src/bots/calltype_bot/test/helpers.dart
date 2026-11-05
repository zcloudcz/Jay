import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:calltype_core/crypto/device_list.dart';
import 'package:calltype_core/crypto/key_manager.dart';
import 'package:calltype_core/crypto/session_manager.dart';
import 'package:calltype_core/network/hub_transport.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:calltype_core/storage/secret_store.dart';
import 'package:drift/native.dart';

/// 32 zero bytes — a valid BOT_STORE_KEY for tests.
final testStoreKey = base64Encode(List.filled(32, 0));

/// Polls until [condition] holds. Real crypto runs on real time, so tests
/// wait for observable effects instead of pumping a fake clock.
Future<void> until(bool Function() condition, {String? reason}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition never held: ${reason ?? ''}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _MemoryStore extends SecretStore {
  final _values = <String, String>{};
  @override
  Future<String?> read(String key) async => _values[key];
  @override
  Future<void> write(String key, String value) async => _values[key] = value;
  @override
  Future<void> delete(String key) async => _values.remove(key);
}

/// A human user's device: the REAL calltype_core crypto stack, so the tests
/// prove wire compatibility with the app, not with a mock of it.
class FakeUser {
  FakeUser._(this.id, this.keys, this.sessions, this._db);

  final String id;
  final KeyManager keys;
  final SessionManager sessions;
  final AppDatabase _db;
  int _counter = 0;

  static Future<FakeUser> create(String id) async {
    final db = AppDatabase(NativeDatabase.memory());
    final keys = KeyManager(secureStorage: _MemoryStore());
    return FakeUser._(id, keys, SessionManager(database: db, keyManager: keys), db);
  }

  Future<Map<String, dynamic>> keyBundle() async => {
    ...await keys.getSignedIdentityBundle(),
  };

  /// Builds the hub's ReceiveMessage payload for a message to the bot,
  /// exactly as the app's ChatController + the server would produce it.
  Future<Map<String, dynamic>> messageTo(
    String botId,
    Map<String, dynamic> botBundle,
    String text, {
    String? groupId,
    String? messageId,
    String? to,
  }) async {
    if (!await sessions.hasSession(botId)) {
      await sessions.initiateSession(botId, botBundle);
    }
    final mid = messageId ?? '$id-msg-${_counter++}';
    final envelope = await sessions.encryptMessage(
      botId,
      jsonEncode({
        'v': 1,
        'id': mid,
        'body': text,
        'type': 'text',
        'groupId': groupId,
        'groupName': groupId == null ? null : 'Team',
        // Names the conversation of a copy sent by one of the receiver's own
        // devices; absent in ordinary messages.
        'to': ?to,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
      }),
    );
    return {
      'senderId': id,
      'messageId': mid,
      'groupId': groupId,
      'encryptedBody': base64Encode(utf8.encode(envelope)),
    };
  }

  /// Decrypts a body the bot handed to the hub and returns the text.
  Future<String> read(String botId, String encryptedBodyBase64) async {
    final plaintext = await sessions.decryptMessage(
      botId,
      utf8.decode(base64Decode(encryptedBodyBase64)),
    );
    return (jsonDecode(plaintext) as Map<String, dynamic>)['body'] as String;
  }

  Future<void> close() => _db.close();
}

/// In-memory hub: records what the bot invokes, lets the test push messages.
class FakeHub implements HubTransport {
  final invocations = <({String method, List<Object> args})>[];

  /// method -> errors to throw on the next calls of it, one per call. A
  /// function so a test can change the world when the hub "answers".
  final failures = <String, List<Object Function()>>{};
  final _handlers = <String, void Function(List<Object?>?)>{};
  bool _connected = false;

  List<List<Object>> calls(String method) => [
    for (final i in invocations)
      if (i.method == method) i.args,
  ];

  void deliver(Map<String, dynamic> message) =>
      _handlers['ReceiveMessage']!([message]);

  @override
  bool get isConnected => _connected;
  @override
  void on(String method, void Function(List<Object?>?) handler) =>
      _handlers[method] = handler;
  @override
  void onClose(void Function() callback) {}
  @override
  void onReconnecting(void Function() callback) {}
  @override
  void onReconnected(void Function() callback) {}
  @override
  Future<void> start() async => _connected = true;
  @override
  Future<void> stop() async => _connected = false;
  @override
  Future<void> invoke(String method, [List<Object> args = const []]) async {
    invocations.add((method: method, args: args));
    // Scripted hub errors: each entry fails ONE call of [method] (the attempt
    // is still recorded above, like a hub that received and refused it).
    final queue = failures[method];
    if (queue != null && queue.isNotEmpty) throw queue.removeAt(0)();
  }
}

/// The REST endpoints the bot touches, on a loopback HttpServer.
class FakeApi {
  FakeApi._(this._server);

  final HttpServer _server;
  static const botId = '00000000-0000-4000-8000-0000000000b0';
  static const botHandle = 'CT-BOT1-0001';

  final registrations = <Map<String, dynamic>>[];
  final keyBundles = <String, Map<String, dynamic>>{};
  final groups = <String, List<String>>{};
  final handles = <String, String>{};

  /// GET /devices/{id}/device-list bodies, keyed by EVERY device id of the
  /// list (the real server answers for the primary and its companions).
  final deviceLists = <String, Map<String, dynamic>>{};

  String get url => 'http://127.0.0.1:${_server.port}';

  int _nextOneTimeKey = 0;

  /// The bundle a user would fetch for the bot, from what the bot uploaded.
  /// Like the real endpoint, every fetch consumes the NEXT one-time pre-key.
  Map<String, dynamic> get botBundle {
    final r = registrations.single;
    return {
      'identityKey': r['identityKey'],
      'signedPreKey': r['signedPreKey'],
      'signingKey': r['signingKey'],
      'signature': r['signature'],
      'oneTimePreKey': (r['oneTimePreKeys'] as List)[_nextOneTimeKey++],
    };
  }

  static Future<FakeApi> start() async {
    final api = FakeApi._(await HttpServer.bind('127.0.0.1', 0));
    api._server.listen(api._serve);
    return api;
  }

  Future<void> _serve(HttpRequest request) async {
    final path = request.uri.path;
    final segments = request.uri.pathSegments;
    Object? body;
    if (request.method == 'POST' && path == '/devices') {
      registrations.add(
        jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>,
      );
      body = {'deviceId': botId, 'userHandle': botHandle, 'deviceSecret': 's'};
    } else if (path == '/auth/token') {
      body = {
        'token': 'jwt',
        'expiresAt': DateTime.now()
            .add(const Duration(days: 1))
            .toUtc()
            .toIso8601String(),
      };
    } else if (segments.length == 3 && segments[2] == 'key-bundle') {
      body = keyBundles[segments[1]];
    } else if (segments.length == 3 && segments[2] == 'device-list') {
      body = deviceLists[segments[1]];
    } else if (segments.length == 3 && segments[0] == 'groups') {
      body = [
        for (final id in groups[segments[1]] ?? <String>[]) {'deviceId': id},
      ];
    } else if (segments.length == 3 && segments[1] == 'by-handle') {
      final id = handles[segments[2]];
      body = id == null ? null : {'deviceId': id, 'userHandle': segments[2]};
    }
    request.response.statusCode = body == null ? 404 : 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  Future<void> close() => _server.close(force: true);
}

/// [primary]'s signed device list naming [companions], as the server serves it.
Future<Map<String, dynamic>> signedDeviceList(
  FakeUser primary,
  List<FakeUser> companions, {
  required int version,
}) async {
  final signed = await signDeviceList(
    primarySigningKey: await primary.keys.getSigningKeyPair(),
    list: DeviceList(
      primaryDeviceId: primary.id,
      version: version,
      devices: [
        for (final c in companions)
          DeviceListEntry(
            deviceId: c.id,
            identityKey: await c.keys.getPublicIdentityKey(),
            signingKey: (await c.keys.getSignedIdentityBundle())['signingKey']!,
            consentSig: await signDeviceLinkConsent(
              companionSigningKey: await c.keys.getSigningKeyPair(),
              primaryDeviceId: primary.id,
              companionDeviceId: c.id,
            ),
          ),
      ],
    ),
  );
  return {
    'primaryDeviceId': primary.id,
    'version': version,
    'payload': signed.payload,
    'signature': signed.signature,
  };
}
