import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:calltype_core/crypto/key_manager.dart';
import 'package:calltype_core/crypto/session_manager.dart';
import 'package:calltype_core/network/hub_transport.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:calltype_core/storage/secret_store.dart';
import 'package:calltype_core/storage/drift_protocol_store.dart';
import 'package:drift/native.dart';

/// Polls until [condition] holds. A fixed sleep is a guess about how fast the
/// machine is — it failed on a slow CI runner — so tests wait for the
/// observable effect instead (same helper as calltype_bot's tests).
Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition never held');
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

/// A human user's device: real calltype_core crypto, so tests prove wire
/// compatibility with the app rather than with a mock of it. Copied from
/// calltype_bot's test helper (same shape) — kept package-local rather than
/// exported, since it is test-only infrastructure, not archiver behavior.
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
    return FakeUser._(
      id,
      keys,
      SessionManager(store: DriftProtocolStore(db), keyManager: keys),
      db,
    );
  }

  Future<Map<String, dynamic>> keyBundle() async => {
    ...await keys.getSignedIdentityBundle(),
  };

  /// Builds the hub's ReceiveMessage payload for a group message, exactly as
  /// the app + server would produce it for a business-group text/file message.
  Future<Map<String, dynamic>> messageTo(
    String recipientId,
    Map<String, dynamic> recipientBundle,
    String body, {
    required String groupId,
    String type = 'text',
    String? messageId,
  }) async {
    if (!await sessions.hasSession(recipientId)) {
      await sessions.initiateSession(recipientId, recipientBundle);
    }
    final mid = messageId ?? '$id-msg-${_counter++}';
    final envelope = await sessions.encryptMessage(
      recipientId,
      jsonEncode({
        'v': 1,
        'id': mid,
        'body': body,
        'type': type,
        'groupId': groupId,
        'groupName': 'Team',
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

  Future<void> close() => _db.close();
}

/// In-memory hub transport: lets a test push a `ReceiveMessage` payload
/// straight into a real `SignalRClient` without a network round trip.
class FakeHub implements HubTransport {
  final _handlers = <String, void Function(List<Object?>?)>{};
  bool _connected = false;

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
  /// Every hub method the client invoked, in order (same helper shape as
  /// calltype_bot's FakeHub).
  final _invocations = <List<Object>>[];
  List<List<Object>> calls(String method) => [
    for (final i in _invocations)
      if (i.first == method) i,
  ];

  @override
  Future<void> invoke(String method, [List<Object> args = const []]) async =>
      _invocations.add([method, ...args]);
}

/// A loopback `POST /orgs/{orgId}/audit/records` endpoint. Tests configure
/// [responses] (one status code per call, last one repeats) and can inspect
/// [requests] to check what the archiver actually sent — in particular, that
/// no request body ever contains plaintext, and that a duplicate message id
/// is posted exactly once.
class FakeArchiveApi {
  FakeArchiveApi._(this._server);

  final HttpServer _server;
  final requests = <Map<String, dynamic>>[];
  final List<int> responses = [200];
  int _calls = 0;

  String get url => 'http://127.0.0.1:${_server.port}';

  static Future<FakeArchiveApi> start() async {
    final api = FakeArchiveApi._(await HttpServer.bind('127.0.0.1', 0));
    api._server.listen(api._serve);
    return api;
  }

  Future<void> _serve(HttpRequest request) async {
    final body =
        jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;
    requests.add(body);
    final status = responses[_calls.clamp(0, responses.length - 1)];
    _calls++;
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'sequence': _calls}));
    await request.response.close();
  }

  Future<void> close() => _server.close(force: true);
}
