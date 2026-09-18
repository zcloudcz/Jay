import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:calltype_core/auth/auth_service.dart';
import 'package:calltype_core/crypto/group_cipher.dart';
import 'package:calltype_core/crypto/key_manager.dart';
import 'package:calltype_core/crypto/session_manager.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/network/hub_transport.dart';
import 'package:calltype_core/network/signalr_client.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import 'src/encrypted_file_store.dart';
import 'src/ws_hub_transport.dart';

export 'src/encrypted_file_store.dart';
export 'src/ws_hub_transport.dart';

typedef BotMessageHandler = Future<void> Function(BotMessage message);

/// True when [text] addresses the bot: `@<handle>` or `@<display name>`,
/// case-insensitive, not followed by another word character (so `@Hermes`
/// does not fire on `@Hermeskeil`).
bool mentionsBot(String text, {required String handle, String? displayName}) {
  final lower = text.toLowerCase();
  for (final name in [handle, ?displayName]) {
    if (name.isEmpty) continue;
    final pattern = RegExp('@${RegExp.escape(name.toLowerCase())}(?![\\w-])');
    if (pattern.hasMatch(lower)) return true;
  }
  return false;
}

/// One decrypted incoming text message, handed to the bot's handler.
class BotMessage {
  BotMessage._(
    this._bot, {
    required this.id,
    required this.text,
    required this.senderId,
    required this.conversationId,
    required this.isGroup,
    required this.mentionsBot,
    String? groupName,
  }) : _groupName = groupName;

  final CallTypeBot _bot;
  final String? _groupName;

  /// Server-unique message UUID — the idempotence key.
  final String id;
  final String text;
  final String senderId;

  /// Stable per conversation: the peer's device id (1:1) or the group id.
  /// Backends use it to keep separate memory per conversation.
  final String conversationId;
  final bool isGroup;
  final bool mentionsBot;

  /// Sends [text] back into the conversation this message came from.
  Future<void> reply(String text) => _bot._send(
    conversationId,
    text,
    groupId: isGroup ? conversationId : null,
    groupName: _groupName,
  );
}

/// A headless CallType device that answers messages through a handler.
///
/// It does what the Flutter app does (register, connect, decrypt, ack, send)
/// with the same `calltype_core` protocol code, so the server cannot tell a
/// bot from a person apart from the self-declared `isBot` flag.
class CallTypeBot {
  CallTypeBot._(
    this._db,
    this._api,
    this._sessions,
    this._signalR,
    this.deviceId,
    this.handle,
    this.displayName,
    this._log,
    this._sendRetryDelay,
  );

  final AppDatabase _db;
  final ApiClient _api;
  final SessionManager _sessions;
  final SignalRClient _signalR;
  final void Function(String) _log;
  final Duration _sendRetryDelay;

  final String deviceId;

  /// Human-readable `CT-XXXX-XXXX` handle users type to add the bot.
  final String handle;
  final String displayName;

  /// What the app's "add contact" accepts (QR content / pasted invite).
  String get inviteLink => 'ct://$deviceId/$handle';

  BotMessageHandler? _handler;
  bool Function(String senderId)? _allowSender;
  StreamSubscription<Map<String, dynamic>>? _subscription;

  /// ONE queue for everything that touches ratchet state. Double Ratchet
  /// state is read-modify-write in the DB; two interleaved decrypt/encrypt
  /// calls for the same peer would corrupt the chain keys. Same rule as the
  /// app's MessageProcessingQueue.
  Future<void> _crypto = Future.value();

  /// One handler queue PER conversation: replies inside a conversation stay
  /// in order, while a slow LLM answer in one chat does not block another.
  final _conversations = <String, Future<void>>{};

  /// Message ids whose decrypt failure was already logged — the server
  /// re-delivers un-acked messages every 15 s and would flood the log.
  final _reportedFailures = <String>{};

  /// Opens the encrypted store + database and registers the device on first
  /// start. Does NOT connect yet — see [onMessage].
  ///
  /// [storeKeyBase64] defaults to env `BOT_STORE_KEY`. [transportFactory] is
  /// a test seam; production uses [WebSocketHubTransport].
  static Future<CallTypeBot> start({
    required String apiBaseUrl,
    required String storePath,
    String displayName = 'Bot',
    String? storeKeyBase64,
    HubTransportFactory? transportFactory,
    void Function(String line)? log,
    Duration sendRetryDelay = const Duration(seconds: 5),
  }) async {
    log ??= (line) => stdout.writeln(line);
    final key = EncryptedFileStore.parseKey(
      storeKeyBase64 ?? Platform.environment['BOT_STORE_KEY'],
    );
    final store = await EncryptedFileStore.open(storePath, key);
    // Sessions + seen-message ids. Plaintext SQLite, exactly like the app's
    // DB today (documented limitation, see README) — the host is trusted.
    final db = AppDatabase(NativeDatabase(File('$storePath.sqlite')));
    final keys = KeyManager(secureStorage: store);
    final auth = AuthService(secureStorage: store, baseUrl: apiBaseUrl);
    final api = ApiClient(baseUrl: apiBaseUrl, authService: auth);

    var deviceId = await store.getDeviceId();
    var handle = await store.read('ct_user_handle');
    if (deviceId == null || handle == null) {
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
        isBot: true,
      );
      deviceId = result['deviceId'] as String;
      handle = result['userHandle'] as String;
      // The secret is returned exactly once; losing it = a new identity.
      await store.setDeviceSecret(result['deviceSecret'] as String);
      await store.write('ct_user_handle', handle);
      // Written last: its presence marks registration as complete.
      await store.setDeviceId(deviceId);
      log('Registered new bot "$displayName": handle $handle');
      log('Add it in Jay by handle, or paste this invite: ct://$deviceId/$handle');
    }

    return CallTypeBot._(
      db,
      api,
      SessionManager(database: db, keyManager: keys),
      SignalRClient(
        baseUrl: apiBaseUrl,
        deviceId: deviceId,
        authService: auth,
        transportFactory: transportFactory ?? WebSocketHubTransport.new,
      ),
      deviceId,
      handle,
      displayName,
      log,
      sendRetryDelay,
    );
  }

  /// Resolves a `CT-XXXX-XXXX` handle to a device id (null if unknown).
  /// Incoming messages only carry device ids, so allowlists written as
  /// handles are resolved through this.
  Future<String?> deviceIdForHandle(String handle) async {
    try {
      return (await _api.findDeviceByHandle(handle))['deviceId'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Sets the handler and connects.
  ///
  /// WHY connecting happens here and not in [start]: on connect the server
  /// immediately pushes everything queued while the bot was offline. Those
  /// messages must meet a handler (and the allowlist), not an empty runtime.
  ///
  /// [allowSender] is checked BEFORE decryption. A rejected sender's message
  /// is acknowledged and dropped without parsing a byte of it, without a
  /// typing indicator and without the handler — the bot stays silent.
  Future<void> onMessage(
    BotMessageHandler handler, {
    bool Function(String senderId)? allowSender,
  }) async {
    _handler = handler;
    _allowSender = allowSender;
    _subscription ??= _signalR.onMessage.listen(_enqueue);
    await _signalR.connect();
  }

  Future<void> close() async {
    await _subscription?.cancel();
    _signalR.close();
    await _crypto;
    // Bounded: a handler stuck on a dead backend must not block shutdown.
    await Future.wait(
      _conversations.values,
    ).timeout(const Duration(seconds: 10), onTimeout: () => const []);
    await _db.close();
  }

  // -- Receiving --------------------------------------------------------------

  void _enqueue(Map<String, dynamic> data) {
    _crypto = _crypto.then((_) => _receive(data)).catchError((Object e) {
      _log('Unexpected receive failure: $e');
    });
  }

  Future<void> _receive(Map<String, dynamic> data) async {
    final senderId = data['senderId'] as String?;
    final messageId = data['messageId'] as String?;
    final groupId = data['groupId'] as String?;
    if (senderId == null || messageId == null) return;

    if (!(_allowSender?.call(senderId) ?? true)) {
      await _ack(senderId, messageId);
      return;
    }

    // Idempotence across replays AND restarts: the id row is committed in
    // the same transaction as the ratchet advance below. Known id = a
    // re-delivery (our ack was lost, or we crashed mid-handler) — ack only.
    // This makes handling AT-MOST-ONCE on purpose: a backend with tools
    // must never run the same instruction twice; after a crash mid-handler
    // the user simply asks again.
    final seen = await (_db.select(
      _db.messages,
    )..where((m) => m.id.equals(messageId))).getSingleOrNull();
    if (seen != null) {
      await _ack(senderId, messageId);
      return;
    }

    final Map<String, dynamic> payload;
    try {
      payload = await _db.transaction(() async {
        final plaintext = await _sessions.decryptMessage(
          senderId,
          utf8.decode(base64Decode(data['encryptedBody'] as String)),
          deferPreKeyCleanup: true,
        );
        final decoded = jsonDecode(plaintext) as Map<String, dynamic>;
        // The inner (encrypted, authenticated) payload must agree with the
        // outer (server-controlled) routing data — otherwise the server
        // could replay a 1:1 message into a group or under another id.
        if (decoded['v'] != 1 ||
            decoded['id'] != messageId ||
            decoded['groupId'] != groupId ||
            decoded['body'] is! String) {
          throw const FormatException('Message context mismatch');
        }
        await _db
            .into(_db.messages)
            .insert(
              MessagesCompanion.insert(
                id: messageId,
                conversationId: groupId ?? senderId,
                senderId: senderId,
                // Body deliberately NOT stored: only the id is needed for
                // idempotence, and less plaintext on disk is better.
                status: const Value('seen'),
                createdAt: DateTime.now(),
              ),
            );
        return decoded;
      });
      await _sessions.finalizePreKeyCleanup();
    } catch (error) {
      // Not acked, like the app: a message we could not authenticate is
      // never reported as delivered. It expires with the server's TTL.
      if (_reportedFailures.add(messageId)) {
        _log('Cannot decrypt message $messageId from $senderId: $error');
      }
      return;
    }

    final body = payload['body'] as String;
    final mentioned = mentionsBot(
      body,
      handle: handle,
      displayName: displayName,
    );
    // v1 is text only; in groups the bot speaks only when addressed
    // (decision §7.1) — everything else is acknowledged and ignored.
    if ((payload['type'] ?? 'text') != 'text' ||
        (groupId != null && !mentioned)) {
      await _ack(senderId, messageId);
      return;
    }

    final message = BotMessage._(
      this,
      id: messageId,
      text: body,
      senderId: senderId,
      conversationId: groupId ?? senderId,
      isGroup: groupId != null,
      mentionsBot: mentioned,
      groupName: payload['groupName'] as String?,
    );
    final tail = _conversations[message.conversationId] ?? Future.value();
    late final Future<void> next;
    next = tail.then((_) => _handle(message)).whenComplete(() {
      // Drop finished chains so the map does not grow with every peer ever.
      if (_conversations[message.conversationId] == next) {
        _conversations.remove(message.conversationId);
      }
    });
    _conversations[message.conversationId] = next;
  }

  Future<void> _handle(BotMessage message) async {
    // The app shows "typing…" for a few seconds per signal, so repeat it
    // while a slow backend is thinking.
    void typing() => unawaited(
      _signalR.sendTypingIndicator(message.conversationId).catchError((_) {}),
    );
    typing();
    final timer = Timer.periodic(const Duration(seconds: 4), (_) => typing());
    try {
      await _handler!(message);
    } catch (error, stack) {
      _log('Handler failed for message ${message.id}: $error\n$stack');
      try {
        await message.reply('Sorry, something went wrong. Please try again.');
      } catch (e) {
        _log('Could not send the apology either: $e');
      }
    } finally {
      timer.cancel();
    }
    // Ack only now: if the process dies mid-handler the server still holds
    // the message, re-delivers it, and the seen-row turns that into a plain
    // ack instead of a second backend call.
    await _ack(message.senderId, message.id);
  }

  Future<void> _ack(String senderId, String messageId) async {
    try {
      await _signalR.acknowledgeMessage(senderId, messageId);
    } catch (_) {
      // Offline: the server re-delivers, and the seen-row acks it then.
    }
  }

  // -- Sending ----------------------------------------------------------------

  Future<void> _send(
    String conversationId,
    String text, {
    String? groupId,
    String? groupName,
  }) async {
    final messageId = _uuidV4();
    final payload = jsonEncode({
      'v': 1,
      'id': messageId,
      'body': text,
      'type': 'text',
      'groupId': groupId,
      'groupName': groupName,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    });

    // Encrypt once (inside the crypto queue), then retry only the network
    // send: re-encrypting would advance the ratchet for a message the peer
    // may already have received.
    final encrypt = _crypto.then((_) async {
      final recipients = groupId == null
          ? [conversationId]
          : (await _api.getGroupMembers(
              groupId,
            )).where((id) => id != deviceId).toList();
      return _db.transaction(() async {
        if (groupId == null) {
          await _ensureSession(conversationId);
          return {
            conversationId: base64Encode(
              utf8.encode(
                await _sessions.encryptMessage(conversationId, payload),
              ),
            ),
          };
        }
        // Per-member fan-out, as in the app (Sender Keys are not in v1).
        final encrypted = await GroupCipher(
          sessionManager: _sessions,
          ensureSession: _ensureSession,
        ).encryptForGroup(groupId, recipients, payload);
        return encrypted.map((id, bytes) => MapEntry(id, base64Encode(bytes)));
      });
    });
    _crypto = encrypt.then<void>((_) {}, onError: (Object _) {});
    final envelopes = await encrypt;

    // ponytail: 3 attempts, then the reply is lost (logged by the caller's
    // error path). Add a persistent outbox like the app's if this bites.
    for (var attempt = 1; ; attempt++) {
      try {
        // Groups: the whole fan-out in one call (see sendGroupMessage) —
        // a business group rejects any call without the auditor's envelope.
        groupId == null
            ? await _signalR.sendMessage(
                envelopes.keys.single,
                envelopes.values.single,
                messageId: messageId,
              )
            : await _signalR.sendGroupMessage(
                groupId,
                envelopes,
                messageId: messageId,
              );
        return;
      } catch (_) {
        if (attempt == 3) rethrow;
        await Future<void>.delayed(_sendRetryDelay);
      }
    }
  }

  Future<void> _ensureSession(String peer) async {
    if (!await _sessions.hasSession(peer)) {
      await _sessions.initiateSession(peer, await _api.getKeyBundle(peer));
    }
  }

  static final _random = Random.secure();

  /// RFC 4122 v4 UUID — the hub parses message ids as GUIDs. Six lines beat
  /// a dependency.
  static String _uuidV4() {
    final b = List<int>.generate(16, (_) => _random.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20)}';
  }
}
