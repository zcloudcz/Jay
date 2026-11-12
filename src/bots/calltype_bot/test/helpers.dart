import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:calltype_core/crypto/device_list.dart';
import 'package:calltype_core/crypto/key_manager.dart';
import 'package:calltype_core/crypto/session_manager.dart';
import 'package:calltype_core/media/media_crypto.dart';
import 'package:calltype_core/media/media_info.dart';
import 'package:calltype_core/network/hub_transport.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:calltype_core/storage/secret_store.dart';
import 'package:calltype_core/storage/drift_protocol_store.dart';
import 'package:crypto/crypto.dart' as crypto;
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
    return FakeUser._(id, keys, SessionManager(store: DriftProtocolStore(db), keyManager: keys), db);
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
    Map<String, dynamic> extra = const {},
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
        // Agent-messaging keys (replyTo, mentions, action, type override).
        ...extra,
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
  Future<String> read(String botId, String encryptedBodyBase64) async =>
      (await readPayload(botId, encryptedBodyBase64))['body'] as String;

  /// Decrypts a body the bot handed to the hub and returns the whole payload.
  Future<Map<String, dynamic>> readPayload(
    String botId,
    String encryptedBodyBase64,
  ) async {
    final plaintext = await sessions.decryptMessage(
      botId,
      utf8.decode(base64Decode(encryptedBodyBase64)),
    );
    return jsonDecode(plaintext) as Map<String, dynamic>;
  }

  Future<void> close() => _db.close();
}

/// In-memory hub: records what the bot invokes, lets the test push messages.
///
/// A silent send (`SendReliable...Silent`, spec 2026-11-11-bot-ack-reactions)
/// is recorded under its PLAIN method name with `silent: true`, so ratchet
/// ordered transcripts over one method still see every message in order.
/// [wireMethods] keeps the names as invoked.
class FakeHub implements HubTransport {
  final invocations = <({String method, List<Object> args, bool silent})>[];
  final wireMethods = <String>[];

  /// method -> errors to throw on the next calls of it, one per call. A
  /// function so a test can change the world when the hub "answers".
  final failures = <String, List<Object Function()>>{};
  final _handlers = <String, void Function(List<Object?>?)>{};
  bool _connected = false;

  List<List<Object>> calls(String method) => [
    for (final i in invocations)
      if (i.method == method) i.args,
  ];

  /// Whether each call of [method] (as in [calls]) was a silent send.
  List<bool> silentFlags(String method) => [
    for (final i in invocations)
      if (i.method == method) i.silent,
  ];

  void deliver(Map<String, dynamic> message) =>
      _handlers['ReceiveMessage']!([message]);

  /// Any other server-to-client call, e.g. the `GroupChanged` hint.
  void push(String method, Map<String, dynamic> data) =>
      _handlers[method]?.call([data]);

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
    wireMethods.add(method);
    final silent =
        method.startsWith('SendReliable') && method.endsWith('Silent');
    invocations.add((
      method: silent ? method.substring(0, method.length - 6) : method,
      args: args,
      silent: silent,
    ));
    // Scripted hub errors: each entry fails ONE call of [method] (the attempt
    // is still recorded above, like a hub that received and refused it).
    // The wire name first (an old server without the Silent twin), then the
    // plain name, which also covers its silent twin like before the split.
    var queue = failures[method];
    if (queue == null || queue.isEmpty) queue = failures[invocations.last.method];
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

  /// GET /groups/{id} bodies. A group in [groups] without an entry here
  /// answers like a server from before bot conversations (no `botTalk`).
  final groupDetails = <String, Map<String, dynamic>>{};

  /// Extra member fields (role, isBot, userHandle) per device id, merged into
  /// every GET /groups/{id}/members row of that device.
  final memberFields = <String, Map<String, dynamic>>{};

  /// Every request as `METHOD /path`, for cache assertions.
  final requests = <String>[];

  /// GET /devices/{id}/device-list bodies, keyed by EVERY device id of the
  /// list (the real server answers for the primary and its companions).
  final deviceLists = <String, Map<String, dynamic>>{};

  /// PUT /devices/{id}/bot-commands bodies, served back by GET.
  final botCommands = <String, Object?>{};

  /// PUT /devices/{id}/bot-policy bodies (bot-access A1). Null in
  /// [policySupported] = the endpoint answers 404 like an old server.
  final botPolicies = <String, Map<String, dynamic>>{};
  bool policySupported = true;

  /// One-time pre-keys the server holds for the bot (bot-access A6); null =
  /// an old server without the endpoints (404).
  int? preKeyCount;
  final uploadedPreKeys = <Map<String, dynamic>>[];

  /// GET /channels/{idOrHandle} bodies, keyed by id AND handle (upper-case
  /// handle; the lookup upper-cases like the server's case-insensitive one).
  final channels = <String, Map<String, dynamic>>{};

  /// POST /channels/{id}/posts bodies as received, with the channel id.
  final channelPosts = <({String channelId, Map<String, dynamic> body})>[];

  /// Scripted refusal of the next channel posts, one per POST:
  /// (status, error body or null for the server's bodyless role 403).
  final channelPostFailures = <(int, Map<String, dynamic>?)>[];

  /// GET /media/{id}: encrypted blobs by media id (lower-case).
  final media = <String, List<int>>{};

  /// GET /media/{id} answers this status instead (e.g. 410 expired).
  final mediaStatus = <String, int>{};

  /// Uploads in progress (POST /media .. complete): id -> declared sizes
  /// and the chunks received. `complete` moves the blob into [media].
  final uploads =
      <String, ({int size, int chunkSize, Map<int, List<int>> chunks})>{};

  /// Ids withdrawn with DELETE /media/{id}.
  final deletedMedia = <String>[];

  /// Scripted refusal of the next POST /media: (status, error code).
  (int, String)? mediaCreateFailure;

  /// The next N chunk PUTs answer 503 (a transient error to retry).
  int failChunkPuts = 0;
  int _nextMediaId = 1;

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
    requests.add('${request.method} $path');
    Object? body;
    if (segments.length == 2 &&
        segments[0] == 'media' &&
        request.method == 'GET') {
      final id = segments[1].toLowerCase();
      final blob = media[id];
      final status = mediaStatus[id] ?? (blob == null ? 404 : 200);
      request.response.statusCode = status;
      if (status == 200) {
        request.response.headers.contentType = ContentType.binary;
        request.response.contentLength = blob!.length;
        request.response.add(blob);
      }
      await request.response.close();
      return;
    }
    if (segments.isNotEmpty && segments[0] == 'media') {
      final handled = await _serveMediaUpload(request, segments);
      if (handled) return;
    }
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
    } else if (segments.length == 2 && segments[0] == 'groups') {
      final id = segments[1];
      body = groupDetails[id] ??
          (groups.containsKey(id) ? {'groupId': id, 'organizationId': null} : null);
    } else if (segments.length == 3 && segments[0] == 'groups') {
      body = [
        for (final id in groups[segments[1]] ?? <String>[])
          {'deviceId': id, 'role': 'member', ...?memberFields[id]},
      ];
    } else if (segments.length == 3 && segments[2] == 'bot-policy') {
      if (policySupported) {
        final sent =
            jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;
        botPolicies[segments[1]] = sent;
        body = sent;
      }
    } else if (segments.length == 4 && segments[2] == 'one-time-prekeys') {
      body = preKeyCount == null ? null : {'count': preKeyCount};
    } else if (segments.length == 3 &&
        segments[2] == 'one-time-prekeys' &&
        preKeyCount != null) {
      final sent =
          jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;
      final keys = (sent['oneTimePreKeys'] as List).cast<Map<String, dynamic>>();
      uploadedPreKeys.addAll(keys);
      preKeyCount = preKeyCount! + keys.length;
      body = {'count': preKeyCount};
    } else if (segments.length == 3 && segments[2] == 'bot-commands') {
      if (request.method == 'PUT') {
        botCommands[segments[1]] = jsonDecode(
          await utf8.decodeStream(request),
        );
      }
      body = botCommands[segments[1]] ?? {'commands': []};
    } else if (segments.length == 2 &&
        segments[0] == 'channels' &&
        request.method == 'GET') {
      body = channels[segments[1]] ?? channels[segments[1].toUpperCase()];
    } else if (segments.length == 3 &&
        segments[0] == 'channels' &&
        segments[2] == 'posts' &&
        request.method == 'POST') {
      final sent =
          jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;
      if (channelPostFailures.isNotEmpty) {
        final (status, error) = channelPostFailures.removeAt(0);
        request.response.statusCode = status;
        request.response.headers.contentType = ContentType.json;
        if (error != null) request.response.write(jsonEncode(error));
        await request.response.close();
        return;
      }
      channelPosts.add((channelId: segments[1], body: sent));
      body = {
        ...sent,
        'channelId': segments[1],
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'byBot': true,
      };
    } else if (segments.length == 3 && segments[1] == 'by-handle') {
      final id = handles[segments[2]];
      body = id == null ? null : {'deviceId': id, 'userHandle': segments[2]};
    }
    request.response.statusCode = body == null ? 404 : 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  /// The upload half of the media relay (contract section 2), strict about
  /// sizes like the real server. Returns false for routes it does not own.
  Future<bool> _serveMediaUpload(
    HttpRequest request,
    List<String> segments,
  ) async {
    Future<bool> answer(int status, [Object? body]) async {
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      if (body != null) request.response.write(jsonEncode(body));
      await request.response.close();
      return true;
    }

    final method = request.method;
    if (segments.length == 1 && method == 'POST') {
      final json =
          jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;
      final failure = mediaCreateFailure;
      if (failure != null) {
        mediaCreateFailure = null;
        return answer(failure.$1, {'error': 'refused', 'code': failure.$2});
      }
      final size = json['size'] as int;
      final chunkSize = json['chunkSize'] as int;
      if (chunkSize < mediaMinChunkSize + 16 ||
          chunkSize > mediaMaxChunkSize + 16 ||
          size < 16) {
        return answer(400, {'code': 'invalid_media_size'});
      }
      final id =
          '00000000-0000-4000-8000-${(_nextMediaId++).toString().padLeft(12, '0')}';
      uploads[id] = (size: size, chunkSize: chunkSize, chunks: {});
      return answer(201, {
        'id': id,
        'chunkSize': chunkSize,
        'chunkCount': (size + chunkSize - 1) ~/ chunkSize,
        'uploadExpiresAt': DateTime.now()
            .add(const Duration(hours: 24))
            .toUtc()
            .toIso8601String(),
      });
    }
    final id = segments.length > 1 ? segments[1].toLowerCase() : '';
    final upload = uploads[id];
    if (segments.length == 4 && segments[2] == 'chunks' && method == 'PUT') {
      final bytes = BytesBuilder();
      await for (final chunk in request) {
        bytes.add(chunk);
      }
      if (failChunkPuts > 0) {
        failChunkPuts--;
        return answer(503, {'code': 'unavailable'});
      }
      if (upload == null) return answer(404, {'code': 'media_not_found'});
      final index = int.parse(segments[3]);
      final count = (upload.size + upload.chunkSize - 1) ~/ upload.chunkSize;
      final expected = index == count - 1
          ? upload.size - upload.chunkSize * (count - 1)
          : upload.chunkSize;
      if (index < 0 || index >= count || bytes.length != expected) {
        return answer(400, {'code': 'invalid_chunk'});
      }
      upload.chunks[index] = bytes.toBytes();
      return answer(204);
    }
    if (segments.length == 3 && segments[2] == 'complete' && method == 'POST') {
      if (upload == null) return answer(404, {'code': 'media_not_found'});
      final count = (upload.size + upload.chunkSize - 1) ~/ upload.chunkSize;
      final missing = [
        for (var i = 0; i < count; i++)
          if (!upload.chunks.containsKey(i)) i,
      ];
      if (missing.isNotEmpty) {
        return answer(409, {'code': 'media_incomplete', 'missing': missing});
      }
      media[id] = [for (var i = 0; i < count; i++) ...upload.chunks[i]!];
      return answer(200, {
        'id': id,
        'size': upload.size,
        'expiresAt': DateTime.now()
            .add(const Duration(hours: 72))
            .toUtc()
            .toIso8601String(),
      });
    }
    if (segments.length == 2 && method == 'DELETE') {
      deletedMedia.add(id);
      uploads.remove(id);
      media.remove(id);
      return answer(204);
    }
    return false;
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

/// Encrypts [plain] exactly like the app's upload (calltype_core
/// MediaCipher), stores the blob on [api] under [id] and returns the
/// `media` object the app puts into the message.
Future<Map<String, Object?>> uploadMedia(
  FakeApi api,
  Uint8List plain, {
  String id = '11111111-2222-4333-8444-555555555555',
  MediaKind kind = MediaKind.voice,
  String name = 'voice.m4a',
  String mime = 'audio/mp4',
  int chunkSize = mediaMinChunkSize,
  int? durationMs = 10400,
  String? caption,
}) async {
  final keys = newMediaKey();
  final cipher = MediaCipher(
    key: keys.key,
    noncePrefix: keys.nonce,
    size: plain.length,
    chunkSize: chunkSize,
  );
  final blob = BytesBuilder();
  for (var i = 0; i < cipher.chunkCount; i++) {
    final start = i * chunkSize;
    final end = start + mediaPlainChunkLength(plain.length, chunkSize, i);
    blob.add(await cipher.encryptChunk(i, plain.sublist(start, end)));
  }
  api.media[id] = blob.toBytes();
  return MediaInfo(
    id: id,
    kind: kind,
    name: name,
    mime: mime,
    size: plain.length,
    sha256: Uint8List.fromList(crypto.sha256.convert(plain).bytes),
    key: keys.key,
    nonce: keys.nonce,
    chunkSize: chunkSize,
    expiresAt: DateTime.now().toUtc().add(const Duration(days: 3)),
    durationMs: durationMs,
    caption: caption,
  ).toJson();
}
