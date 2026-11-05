import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:calltype_core/auth/auth_service.dart';
import 'package:calltype_core/crypto/device_list.dart' show DeviceListException;
import 'package:calltype_core/crypto/group_cipher.dart';
import 'package:calltype_core/crypto/key_manager.dart';
import 'package:calltype_core/crypto/session_manager.dart';
import 'package:calltype_core/devices/device_directory.dart';
import 'package:calltype_core/devices/fanout_sender.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/network/hub_transport.dart';
import 'package:calltype_core/network/signalr_client.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import 'src/encrypted_file_store.dart';
import 'src/group_info.dart';
import 'src/ws_hub_transport.dart';

export 'package:calltype_core/network/group_dtos.dart'
    show BotTalkMode, BotTalkSettings, MuteMode, MuteSetting;
export 'src/encrypted_file_store.dart';
export 'src/group_info.dart';
export 'src/ws_hub_transport.dart';

typedef BotMessageHandler = Future<void> Function(BotMessage message);

/// Second-chance pre-decrypt check for a sender [allowSender] refused, when
/// the server says the message belongs to group [groupId]. See [CallTypeBot.onMessage].
typedef GroupSenderCheck =
    Future<bool> Function(String senderId, String groupId);

/// [CallTypeBot.send] could not address [to] (unknown handle, not a member).
class BotSendException implements Exception {
  const BotSendException(this.message);
  final String message;
  @override
  String toString() => 'BotSendException: $message';
}

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
    required String ackSenderId,
    this.groupId,
    String? groupName,
  }) : _groupName = groupName,
       _ackSenderId = ackSenderId;

  final CallTypeBot _bot;
  final String? _groupName;

  /// The device that actually sent it. The server queues per device, so the
  /// acknowledgement must name this one, not the identity in [senderId].
  final String _ackSenderId;

  /// Server-unique message UUID — the idempotence key.
  final String id;
  final String text;

  /// The sender's IDENTITY (a user's primary device id): the same for every
  /// device of that user, so allowlists and per-user memory keep working.
  final String senderId;

  /// Stable per conversation: the peer's identity id (1:1) or the group id.
  /// Backends use it to keep separate memory per conversation.
  final String conversationId;
  final bool isGroup;
  final bool mentionsBot;

  /// The group this message was posted in; null for a 1:1 message.
  final String? groupId;

  /// Whether the sender is a bot device, from the group's member list.
  /// Null when unknown: 1:1 messages, or the member list could not be read.
  bool? get senderIsBot => _senderIsBot;
  bool? _senderIsBot;

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
    this._directory,
    this._fanout,
    this.deviceId,
    this.handle,
    this.displayName,
    this._log,
    this._sendRetryDelay,
    this._groupCacheTtl,
  );

  final AppDatabase _db;
  final ApiClient _api;
  final SessionManager _sessions;
  final SignalRClient _signalR;

  /// Multi-device: who owns which device (a user's companion belongs to the
  /// user's conversation) and the per-device envelopes of a reply.
  final DeviceDirectory _directory;
  final FanoutSender _fanout;
  final void Function(String) _log;
  final Duration _sendRetryDelay;
  final Duration _groupCacheTtl;

  final String deviceId;

  /// Human-readable `CT-XXXX-XXXX` handle users type to add the bot.
  final String handle;
  final String displayName;

  /// What the app's "add contact" accepts (QR content / pasted invite).
  String get inviteLink => 'ct://$deviceId/$handle';

  BotMessageHandler? _handler;
  bool Function(String senderId)? _allowSender;
  GroupSenderCheck? _allowGroupSender;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  final _hintSubscriptions = <StreamSubscription<Map<String, dynamic>>>[];

  /// group id (lower-case) -> member list + settings, with its fetch time.
  /// WHY a cache: the bridge checks the group on every bot message; one REST
  /// round trip per message would be wasteful and slow. It is dropped on the
  /// server's hints (see [invalidateGroups]) and after [_groupCacheTtl] as a
  /// safety net for a missed hint.
  final _groups = <String, ({DateTime at, Future<GroupInfo> info})>{};

  /// Last group name seen in an incoming payload, so a message the bot starts
  /// itself ([send]) shows the same name in the app as a reply would.
  final _groupNames = <String, String>{};

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
    Duration groupCacheTtl = const Duration(minutes: 5),
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

    final sessions = SessionManager(database: db, keyManager: keys);
    final directory = DeviceDirectory(
      database: db,
      apiClient: api,
      selfDeviceId: deviceId,
      selfSigningKey: () async =>
          (await keys.getSignedIdentityBundle())['signingKey']!,
      selfIdentityKey: keys.getPublicIdentityKey,
    );
    await directory.load();
    return CallTypeBot._(
      db,
      api,
      sessions,
      SignalRClient(
        baseUrl: apiBaseUrl,
        deviceId: deviceId,
        authService: auth,
        transportFactory: transportFactory ?? WebSocketHubTransport.new,
      ),
      directory,
      FanoutSender(
        directory: directory,
        sessions: sessions,
        apiClient: api,
        // A listed companion of the user vanished from the server: the bot
        // has no one to ask, so the log is the only place to surface it.
        onMissingDevice: (id) => log!('Skipped listed device $id: its key bundle is gone'),
      ),
      deviceId,
      handle,
      displayName,
      log,
      sendRetryDelay,
      groupCacheTtl,
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
  ///
  /// [allowGroupSender] is consulted only when [allowSender] refused and the
  /// server routes the message to a group. It may do a (cached) group lookup,
  /// so a bot can admit other bots of groups it is in without knowing them in
  /// advance; the final decision still belongs to the handler, which sees the
  /// authenticated group id.
  Future<void> onMessage(
    BotMessageHandler handler, {
    bool Function(String senderId)? allowSender,
    GroupSenderCheck? allowGroupSender,
  }) async {
    _handler = handler;
    _allowSender = allowSender;
    _allowGroupSender = allowGroupSender;
    if (_subscription == null) {
      _subscription = _signalR.onMessage.listen(_enqueue);
      _hintSubscriptions.addAll([
        _signalR.onGroupChanged.listen(
          (hint) => invalidateGroups(hint['groupId'] as String?),
        ),
        // A changed device list can change who an identity is; cheap to
        // re-read, and wrong membership data would be worse.
        _signalR.onDeviceListChanged.listen((_) => invalidateGroups()),
      ]);
    }
    await _signalR.connect();
  }

  // -- Groups -----------------------------------------------------------------

  /// The bot-talk setting and members of [groupId] (the bot must be a member,
  /// the server refuses otherwise). Cached; see [_groups].
  ///
  /// An old server without `botTalk` yields [BotTalkSettings.off].
  Future<GroupInfo> group(String groupId) {
    final key = groupId.toLowerCase();
    final cached = _groups[key];
    final now = DateTime.now();
    if (cached != null && now.difference(cached.at) < _groupCacheTtl) {
      return cached.info;
    }
    final info = _loadGroup(groupId);
    _groups[key] = (at: now, info: info);
    // A failure must not stay cached: the next call asks the server again.
    info.then<void>(
      (_) {},
      onError: (Object _) {
        if (_groups[key]?.info == info) _groups.remove(key);
      },
    );
    return info;
  }

  /// Forgets the cached [group] data of [groupId], or of every group.
  void invalidateGroups([String? groupId]) => groupId == null
      ? _groups.clear()
      : _groups.remove(groupId.toLowerCase());

  Future<GroupInfo> _loadGroup(String groupId) async {
    final (details, members) = await (
      _api.getGroup(groupId),
      _api.getGroupMemberInfos(groupId),
    ).wait;
    return GroupInfo(
      groupId: groupId,
      botTalk: details.botTalk,
      myMute: details.myMute,
      members: [
        for (final m in members)
          GroupMember(
            deviceId: m.deviceId.toLowerCase(),
            role: m.role,
            handle: m.userHandle,
            displayName: m.displayName,
            isBot: m.isBot,
          ),
      ],
    );
  }

  // -- Starting a message -----------------------------------------------------

  static final _handlePattern = RegExp(
    r'^CT-[A-Z0-9]{4}-[A-Z0-9]{4}$',
    caseSensitive: false,
  );

  /// Starts a message instead of replying to one.
  ///
  /// [to] is a `CT-XXXX-XXXX` handle (1:1; every device of that user gets a
  /// copy, like a reply) or the id of a group the bot is a member of (the
  /// same per-device group fan-out as a group reply). WHO the bot may write
  /// to is the caller's policy (the Hermes bridge allows only its owners);
  /// the runtime only refuses what it cannot address, with [BotSendException].
  /// Like a reply it needs the hub connection, so call [onMessage] first.
  Future<void> send({required String to, required String text}) async {
    final target = to.trim();
    if (text.trim().isEmpty) {
      throw ArgumentError.value(text, 'text', 'must not be empty');
    }
    if (_handlePattern.hasMatch(target)) {
      final id = await deviceIdForHandle(target.toUpperCase());
      if (id == null) throw BotSendException('Unknown handle $target.');
      if (!await _sessions.hasSession(id)) {
        // First contact: learn the user's signed device list up front, as the
        // receive path does, so every companion gets its copy right away
        // instead of after a device_list_stale round trip.
        try {
          await _inCrypto(
            () => _directory.refresh(id, ensurePinned: _ensureSession),
          );
        } on DeviceListException {
          // No verified list: the device is its own identity, as before.
        }
      }
      final identity = await _directory.identityOf(id);
      if (identity == deviceId.toLowerCase()) {
        throw const BotSendException('A bot cannot message itself.');
      }
      await _send(identity, text);
      return;
    }
    var info = await group(target);
    if (!info.isMember(deviceId)) {
      // Maybe the bot was added after the cache was filled.
      invalidateGroups(target);
      info = await group(target);
      if (!info.isMember(deviceId)) {
        throw BotSendException('The bot is not a member of group $target.');
      }
    }
    await _send(
      target,
      text,
      groupId: target,
      groupName: _groupNames[target.toLowerCase()],
    );
  }

  Future<void> close() async {
    await _subscription?.cancel();
    for (final s in _hintSubscriptions) {
      await s.cancel();
    }
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

    // Multi-device: a device the bot never talked to may be a companion of a
    // user it knows. Learn that BEFORE the allowlist, which names users
    // (identities). Only for a sender without a session: one lookup per new
    // device, never one per message.
    if (await _directory.identityOf(senderId) == senderId.toLowerCase() &&
        !await _sessions.hasSession(senderId)) {
      try {
        await _directory.refresh(senderId, ensurePinned: _ensureSession);
      } on DeviceListException {
        // No verified list: the sender stays its own identity, as before.
        // Any other error (network, 5xx) escapes on purpose: the message
        // stays queued on the server and nothing was decrypted yet.
      }
    }
    // The server's attribution is only a HINT. If it names another identity
    // than our verified list does, the list may be stale (the owner removed
    // this companion, maybe a stolen browser): re-read it so the device is no
    // longer treated as the owner. Attribution itself still comes only from
    // the verified list; same error rule as above.
    final hint = (data['senderPrimaryId'] as String?)?.toLowerCase();
    if (hint != null &&
        hint.isNotEmpty &&
        hint != await _directory.identityOf(senderId)) {
      // Group member lists name identities; re-read them with the list.
      invalidateGroups();
      try {
        await _directory.refresh(senderId, ensurePinned: _ensureSession);
      } on DeviceListException {
        // Keep the local view.
      }
    }
    final identity = await _directory.identityOf(senderId);
    var allowed = _allowSender?.call(identity) ?? true;
    final groupCheck = _allowGroupSender;
    if (!allowed && groupId != null && groupCheck != null) {
      // WHY this may hit the network inside the crypto queue: it runs only
      // for senders the cheap check refused, the answer is cached per group,
      // and nothing is decrypted yet. The outer groupId is the server's
      // claim; the inner payload must name the same group (checked below),
      // so a lie only gets the message dropped later.
      try {
        allowed = await groupCheck(identity, groupId);
      } catch (e) {
        allowed = false; // fail closed: cannot verify = do not admit
      }
    }
    if (!allowed) {
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

    final ({Map<String, dynamic> payload, InboundRoute route})? result;
    try {
      result = await _db
          .transaction<({Map<String, dynamic> payload, InboundRoute route})?>(
            () async {
              final plaintext = await _sessions.decryptMessage(
                senderId,
                utf8.decode(base64Decode(data['encryptedBody'] as String)),
                deferPreKeyCleanup: true,
              );
              Map<String, dynamic>? decoded;
              InboundRoute? route;
              try {
                // The keys the device used must be the keys its primary
                // signed. A mismatch is dropped, but only after the ratchet
                // step and the seen-row commit, so a replay is acked instead
                // of decrypted again.
                await _directory.assertListedKeys(senderId);
                decoded = jsonDecode(plaintext) as Map<String, dynamic>;
                // The inner (encrypted, authenticated) payload must agree with
                // the outer (server-controlled) routing data - otherwise the
                // server could replay a 1:1 message into a group or under
                // another id.
                if (decoded['v'] != 1 ||
                    decoded['id'] != messageId ||
                    decoded['groupId'] != groupId ||
                    decoded['body'] is! String) {
                  throw const FormatException('Message context mismatch');
                }
                final to = decoded['to'];
                route = await _directory.routeInbound(
                  senderDeviceId: senderId,
                  groupId: groupId,
                  to: to is String ? to : null,
                );
              } on DeviceListException {
                route = null;
              }
              await _db
                  .into(_db.messages)
                  .insert(
                    MessagesCompanion.insert(
                      id: messageId,
                      conversationId: route?.conversationId ?? groupId ?? identity,
                      senderId: route?.senderIdentityId ?? identity,
                      // Body deliberately NOT stored: only the id is needed for
                      // idempotence, and less plaintext on disk is better.
                      status: const Value('seen'),
                      createdAt: DateTime.now(),
                    ),
                  );
              return route == null ? null : (payload: decoded!, route: route);
            },
          );
      await _sessions.finalizePreKeyCleanup();
    } catch (error) {
      // Not acked, like the app: a message we could not authenticate is
      // never reported as delivered. It expires with the server's TTL.
      if (_reportedFailures.add(messageId)) {
        _log('Cannot decrypt message $messageId from $senderId: $error');
      }
      return;
    }

    // Dropped (keys differ from the signed list), or a copy from one of the
    // bot's own devices (a bot has none; never answer itself).
    if (result == null || result.route.own) {
      await _ack(senderId, messageId);
      return;
    }
    final payload = result.payload;
    final route = result.route;
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

    final groupName = payload['groupName'] as String?;
    if (groupId != null && groupName != null && groupName.isNotEmpty) {
      _groupNames[groupId.toLowerCase()] = groupName;
    }
    final message = BotMessage._(
      this,
      id: messageId,
      text: body,
      senderId: route.senderIdentityId,
      conversationId: route.conversationId,
      isGroup: groupId != null,
      mentionsBot: mentioned,
      ackSenderId: senderId,
      groupId: groupId,
      groupName: groupName,
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
      final groupId = message.groupId;
      if (groupId != null) {
        // Outside the crypto queue on purpose: a slow REST call here only
        // delays this conversation.
        try {
          var info = await group(groupId);
          if (!info.isMember(message.senderId)) {
            // A sender the cached list does not know joined after we cached.
            invalidateGroups(groupId);
            info = await group(groupId);
          }
          message._senderIsBot = info.member(message.senderId)?.isBot;
        } catch (_) {
          // Unknown stays null; the handler decides how to treat that.
        }
      }
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
    await _ack(message._ackSenderId, message.id);
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
      // Multi-device: names the direct conversation for a sender's own other
      // devices; required in every direct payload.
      if (groupId == null) 'to': conversationId,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    });
    Future<List<String>> groupIdentities() async => [
      for (final id in await _api.getGroupMembers(groupId!))
        if (id.toLowerCase() != deviceId.toLowerCase()) id,
    ];
    var identityIds = groupId == null
        ? [conversationId]
        : await groupIdentities();

    // Encrypt once (inside the crypto queue), then retry only the network
    // send: re-encrypting would advance the ratchet for a message the peer
    // may already have received. One envelope per device of every recipient
    // identity (a user's companions included), from verified lists only.
    var envelopes = await _inCrypto(
      () => _db.transaction(() => _fanout.encrypt(identityIds, payload)),
    );
    var businessGroup = false;
    // ponytail: 3 attempts, then the reply is lost (logged by the caller's
    // error path). Add a persistent outbox like the app's if this bites.
    for (var attempt = 1; ; attempt++) {
      try {
        if (businessGroup) {
          // Whole fan-out in one call: the hub rejects a business group call
          // without the auditor's envelope (KB2).
          await _signalR.sendGroupMessage(
            groupId!,
            envelopes,
            messageId: messageId,
          );
        } else if (groupId == null) {
          await _signalR.sendDirectFanout(
            conversationId,
            envelopes,
            messageId: messageId,
          );
        } else {
          await _signalR.sendGroupFanout(
            groupId,
            envelopes,
            messageId: messageId,
          );
        }
        return;
      } catch (e) {
        if (attempt == 3) rethrow;
        final required = SignalRClient.staleRequired(e);
        if (!businessGroup &&
            groupId != null &&
            e.toString().contains('fanout_unsupported_in_business_group')) {
          // The bot cannot tell a business group beforehand. Business groups
          // stay on the per-member call (primary devices only). The refused
          // call queued nothing, so encrypting again only skips a ratchet
          // step for the members.
          businessGroup = true;
          final ids = identityIds;
          envelopes = await _inCrypto(
            () => _db.transaction(() async {
              final encrypted = await GroupCipher(
                sessionManager: _sessions,
                ensureSession: _ensureSession,
              ).encryptForGroup(groupId, ids, payload);
              return encrypted.map(
                (id, bytes) => MapEntry(id, base64Encode(bytes)),
              );
            }),
          );
        } else if (!businessGroup && required != null) {
          if (groupId != null) {
            // The hub computes `required` from the CURRENT membership; a
            // member added since the first attempt would stay unverified and
            // fail every retry. The union is harmless for removed members:
            // reconcile already trims envelopes the hub no longer wants.
            identityIds = {...identityIds, ...await groupIdentities()}.toList();
          }
          // The hub knows a different device set: re-read the lists, keep
          // existing envelopes byte for byte, add or drop the difference.
          final current = envelopes;
          final ids = identityIds;
          envelopes = await _inCrypto(
            () => _fanout.reconcile(
              envelopes: current,
              required: required,
              identityIds: ids,
              payload: payload,
            ),
          );
        } else {
          await Future<void>.delayed(_sendRetryDelay);
        }
      }
    }
  }

  /// Runs [action] in the crypto queue (see [_crypto]) and returns its result.
  Future<T> _inCrypto<T>(Future<T> Function() action) {
    final result = _crypto.then((_) => action());
    _crypto = result.then<void>((_) {}, onError: (Object _) {});
    return result;
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
