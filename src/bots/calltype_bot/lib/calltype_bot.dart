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
import 'package:calltype_core/network/media_api.dart';
import 'package:calltype_core/messaging/agent_payload.dart';
import 'package:calltype_core/messaging/reaction.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/network/bot_dtos.dart';
import 'package:calltype_core/network/channel_dtos.dart' show parseErrorCode;
import 'package:calltype_core/network/hub_transport.dart';
import 'package:calltype_core/network/signalr_client.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import 'src/attachment.dart';
import 'src/encrypted_file_store.dart';
import 'src/group_info.dart';
import 'src/ws_hub_transport.dart';

export 'package:calltype_core/media/media_crypto.dart'
    show MediaHashMismatch, MediaTampered;
export 'package:calltype_core/media/media_info.dart'
    show MediaKind, formatMediaDuration, formatMediaSize;
export 'package:calltype_core/messaging/agent_payload.dart'
    show ActionRef, MessageButton, maxActionId, maxActionLabel, maxActions;
export 'package:calltype_core/messaging/reaction.dart'
    show
        ReactionPayload,
        isValidReactionEmoji,
        maxReactionTargetLength,
        quickReactions,
        reactionType;
export 'package:calltype_core/network/bot_dtos.dart' show BotCommand;
export 'package:calltype_core/network/group_dtos.dart'
    show BotTalkMode, BotTalkSettings, MuteMode, MuteSetting;
export 'src/attachment.dart';
export 'src/encrypted_file_store.dart';
export 'src/group_info.dart';
export 'src/ws_hub_transport.dart';

typedef BotMessageHandler = Future<void> Function(BotMessage message);

/// Handles one emoji reaction, see [CallTypeBot.onReaction].
typedef BotReactionHandler = Future<void> Function(BotReaction reaction);

/// Second-chance pre-decrypt check for a sender [allowSender] refused, when
/// the server says the message belongs to group [groupId]. See [CallTypeBot.onMessage].
typedef GroupSenderCheck =
    Future<bool> Function(String senderId, String groupId);

/// [CallTypeBot.send] could not address [to] (unknown handle, not a member),
/// or the server refused a [CallTypeBot.postToChannel].
class BotSendException implements Exception {
  const BotSendException(this.message, {this.code, this.statusCode});
  final String message;

  /// The server's machine code when it gave one, e.g. [channelSuspendedCode]
  /// or [botPostLimitCode]. Null for refusals the runtime decides itself and
  /// for the server's bodyless role 403.
  final String? code;

  /// HTTP status of a server refusal (403, 404, 429); null otherwise.
  final int? statusCode;

  @override
  String toString() =>
      'BotSendException: $message${code == null ? '' : ' ($code)'}';
}

/// Server code: the channel is suspended by moderation (403).
const channelSuspendedCode = 'channel_suspended';

/// Server code: this bot's daily post limit in the channel is used up (429).
const botPostLimitCode = 'bot_post_limit';

/// The server's limit for a channel post body (UTF-16 code units, which is
/// what both Dart's and C#'s `String.length` count).
const channelPostMaxChars = 4096;

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

/// The message an incoming message replies to (payload `replyTo`).
class BotReplyRef {
  const BotReplyRef({
    required this.id,
    required this.senderId,
    required this.preview,
  });

  final String id;

  /// Identity id of the quoted message's author, as the SENDER claims it.
  final String senderId;

  /// The sender's copy of the quoted text (may be empty).
  final String preview;

  Map<String, dynamic> toJson() => {
    'id': id,
    'senderId': senderId,
    'preview': preview,
  };

  /// Same shape and leniency as the app: a malformed quote is dropped, never
  /// the message.
  static BotReplyRef? parse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final senderId = raw['senderId'];
    final preview = raw['preview'];
    if (id is! String || senderId is! String || id.isEmpty) return null;
    return BotReplyRef(
      id: id,
      senderId: senderId,
      preview: preview is String ? preview : '',
    );
  }
}

/// Group replies quote this many characters of the message they answer.
const replyPreviewChars = 100;

/// First [replyPreviewChars] characters (runes, so an emoji is never cut in
/// half) of [text].
String _preview(String text) => text.runes.length <= replyPreviewChars
    ? text
    : String.fromCharCodes(text.runes.take(replyPreviewChars));

/// One decrypted incoming text message, handed to the bot's handler.
class BotMessage {
  BotMessage._(
    this._bot, {
    required this.id,
    required this.text,
    required this.senderId,
    required this.conversationId,
    required this.isGroup,
    required bool textMentionsBot,
    required String ackSenderId,
    this.groupId,
    String? groupName,
    this.mentions = const [],
    this.replyTo,
    this.action,
    this.attachment,
  }) : _groupName = groupName,
       _textMentionsBot = textMentionsBot,
       _ackSenderId = ackSenderId;

  final CallTypeBot _bot;
  final String? _groupName;
  final bool _textMentionsBot;

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

  /// Structured mentions (identity ids, lower-case) the sender attached.
  final List<String> mentions;

  /// The message this one replies to, if any.
  final BotReplyRef? replyTo;

  /// A button press, if any: [ActionRef.messageId] names the message that
  /// carried the button (usually one of this bot's), [text] is its label.
  final ActionRef? action;

  /// A file that came with the message (voice message, image, audio,
  /// video, any file), or null. For an encrypted media message [text] is
  /// the sender's fallback body (what an old client shows, caption on its
  /// own line), so a text-only handler keeps working; for an inline `file`
  /// message (only with `receiveFiles`, see [CallTypeBot.onMessage]) it is
  /// the caption or ''. Nothing is downloaded until the handler asks.
  final BotAttachment? attachment;

  /// The structured mentions name the bot, or the text says `@handle` /
  /// `@display name` (fallback for clients without structured mentions).
  bool get mentionsBot =>
      mentions.contains(_bot.deviceId.toLowerCase()) || _textMentionsBot;

  /// Replies to a message of this bot. WHY that addresses the bot: in a
  /// group a reply is how people answer a specific participant (Telegram,
  /// Matrix and XMPP do the same), and requiring an extra `@` there is noise.
  bool get repliesToBot =>
      replyTo?.senderId.toLowerCase() == _bot.deviceId.toLowerCase();

  /// In a group the bot handles only addressed messages.
  bool get addressed => mentionsBot || repliesToBot;

  /// The group this message was posted in; null for a 1:1 message.
  final String? groupId;

  /// Whether the sender is a bot device, from the group's member list.
  /// Null when unknown: 1:1 messages, or the member list could not be read.
  bool? get senderIsBot => _senderIsBot;
  bool? _senderIsBot;

  /// Sends [text] (with optional buttons) back into the conversation this
  /// message came from. In a group the reply quotes this message, so readers
  /// see what the bot answers; a 1:1 chat has no ambiguity and no quote.
  Future<BotSentMessage> reply(
    String text, {
    List<MessageButton> actions = const [],
  }) => _bot._sendText(
    conversationId,
    text,
    groupId: isGroup ? conversationId : null,
    groupName: _groupName,
    actions: actions,
    replyTo: isGroup
        ? BotReplyRef(id: id, senderId: senderId, preview: _preview(this.text))
        : null,
  );

  /// Puts [emoji] on this message, in the conversation it came from (see
  /// [CallTypeBot.sendReaction]; no handle lookup needed).
  Future<void> react(String emoji) => _bot._sendReactionBody(
    conversationId,
    _bot._reactionBody(id, emoji),
    groupId: isGroup ? conversationId : null,
    groupName: _groupName,
  );

  /// Removes the bot's reaction from this message.
  Future<void> removeReaction() => react('');
}

/// Characters of a sent message the bot remembers for [BotReaction.targetText].
const reactionTargetChars = 200;

/// How many sent messages the bot remembers for reactions (oldest go first).
const rememberedSentMessages = 500;

/// One emoji reaction (`type: reaction`, spec
/// docs/superpowers/specs/2026-11-07-message-reactions.md): [senderId] put
/// [emoji] on the message [targetId], or removed their reaction ([removed]).
class BotReaction {
  const BotReaction({
    required this.id,
    required this.targetId,
    required this.emoji,
    required this.senderId,
    required this.conversationId,
    required this.isGroup,
    this.groupId,
    this.targetIsOwn = false,
    this.targetText,
  });

  /// Id of the reaction message itself (the idempotence key).
  final String id;

  /// The reacted-to message.
  final String targetId;

  /// One emoji grapheme; '' when the reaction was removed.
  final String emoji;
  bool get removed => emoji.isEmpty;

  /// The reactor's IDENTITY (authenticated, like [BotMessage.senderId]).
  final String senderId;

  /// Peer identity id (1:1) or group id, like [BotMessage.conversationId].
  final String conversationId;
  final bool isGroup;
  final String? groupId;

  /// The target is a message this bot sent (one it still remembers).
  final bool targetIsOwn;

  /// The first [reactionTargetChars] characters of that message, when
  /// [targetIsOwn]; null otherwise.
  final String? targetText;

  @override
  String toString() =>
      'BotReaction(${removed ? 'removed' : emoji} on $targetId by $senderId)';
}

/// A message this bot sent; it can still be edited.
class BotSentMessage {
  BotSentMessage._(
    this._bot, {
    required this.id,
    required this.conversationId,
    required this.groupId,
    required String? groupName,
  }) : _groupName = groupName;

  final CallTypeBot _bot;
  final String? _groupName;

  final String id;

  /// Peer identity id (1:1) or group id, like [BotMessage.conversationId].
  final String conversationId;
  final String? groupId;

  /// Replaces the text (`type: edit`). [actions]: null keeps the buttons,
  /// an empty list removes them, a list replaces them.
  ///
  /// Every edit is a full message to every recipient device and an old app
  /// keeps an unknown type queued until the server TTL, so callers should
  /// throttle edits (the Hermes bridge does).
  Future<void> edit(String text, {List<MessageButton>? actions}) =>
      _bot._sendEdit(this, text, actions: actions);
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
  BotMessageHandler? _actionHandler;
  BotReactionHandler? _reactionHandler;
  bool _receiveFiles = false;

  /// Ids of messages this bot sent WITH buttons (lower-case). Mirrored in
  /// `backupState` as `sent-actions:<id>` so a press after a restart is still
  /// recognised as a press on our own message.
  // ponytail: never pruned; one tiny row per button message. Add a TTL if a
  // bot ever sends buttons at volume.
  final _sentWithActions = <String>{};

  /// Button presses being handled outside the conversation queues, so
  /// [close] can wait for them.
  final _pendingActions = <Future<void>>{};
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
  /// a test seam; production uses [WebSocketHubTransport], which reconnects
  /// when the server stays silent for [hubServerTimeout].
  static Future<CallTypeBot> start({
    required String apiBaseUrl,
    required String storePath,
    String displayName = 'Bot',
    String? storeKeyBase64,
    HubTransportFactory? transportFactory,
    void Function(String line)? log,
    Duration sendRetryDelay = const Duration(seconds: 5),
    Duration groupCacheTtl = const Duration(minutes: 5),
    Duration hubServerTimeout = const Duration(seconds: 60),
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
    // Bounded HTTP: messages are processed one after another, so a request
    // stuck on a half-dead connection would stall every later message (the
    // bot looks deaf). A timed-out request fails like any network error and
    // the message stays queued on the server for the next attempt.
    Dio http() => Dio(
      BaseOptions(
        baseUrl: apiBaseUrl,
        connectTimeout: const Duration(seconds: 20),
        sendTimeout: const Duration(minutes: 2),
        receiveTimeout: const Duration(seconds: 90),
      ),
    );
    final auth = AuthService(
      secureStorage: store,
      baseUrl: apiBaseUrl,
      dio: http(),
    );
    final api = ApiClient(baseUrl: apiBaseUrl, authService: auth, dio: http());

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
        transportFactory:
            transportFactory ??
            (url, token) => WebSocketHubTransport(
              url,
              token,
              serverTimeout: hubServerTimeout,
              log: log,
            ),
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
  ///
  /// Encrypted media messages (voice, images, files; spec
  /// 2026-11-07-encrypted-media) always reach [handler] with
  /// [BotMessage.attachment] set; they are `text` on the wire, so older
  /// runtimes already delivered their fallback text. Old inline `type: file`
  /// messages reach it only with [receiveFiles] (older runtimes acked and
  /// ignored them, and a text-only bot would get an empty text).
  Future<void> onMessage(
    BotMessageHandler handler, {
    bool Function(String senderId)? allowSender,
    GroupSenderCheck? allowGroupSender,
    bool receiveFiles = false,
  }) async {
    _handler = handler;
    _receiveFiles = receiveFiles;
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

  /// Handles button presses on this bot's own messages (see [BotMessage.action]).
  ///
  /// WHY separate from [onMessage]: a press runs OUTSIDE the per-conversation
  /// queue. The conversation's handler may be blocked waiting for exactly
  /// this press (an approval), so queueing the press behind it would
  /// deadlock. Without this handler presses go to the normal handler.
  void onAction(BotMessageHandler handler) => _actionHandler = handler;

  /// Handles emoji reactions (`type: reaction`). Set it BEFORE [onMessage],
  /// which connects. Without it reactions are acknowledged and ignored, as
  /// by older runtimes.
  ///
  /// 1:1: every valid reaction arrives. Group: only reactions to this bot's
  /// own messages (the bot is not addressed otherwise). A reaction runs in
  /// its conversation's queue (after a turn in progress), without a typing
  /// indicator, and is acknowledged after the handler; a failing handler is
  /// logged, never answered.
  ///
  /// While a handler is set the runtime remembers the first
  /// [reactionTargetChars] characters of the last [rememberedSentMessages]
  /// messages it sends (local store, `sent-text:` rows), so
  /// [BotReaction.targetText] can say what the reaction was about.
  void onReaction(BotReactionHandler handler) => _reactionHandler = handler;

  /// Publishes the "/" commands the app suggests for this bot (replaces the
  /// whole list; empty = clear).
  Future<void> setCommands(List<BotCommand> commands) async {
    await _api.setBotCommands(deviceId, commands);
  }

  static final _startPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  /// `calltype://bot/<HANDLE>[?start=<payload>]`: the app opens (or offers to
  /// add) this bot and pre-fills `/start <payload>`; the user still presses
  /// send. [start] must be 1..64 of `[A-Za-z0-9_-]`, so it needs no escaping
  /// and cannot smuggle a second command into the composer.
  String deepLink({String? start}) {
    if (start != null && !_startPattern.hasMatch(start)) {
      throw ArgumentError.value(start, 'start', 'must be 1..64 of [A-Za-z0-9_-]');
    }
    return 'calltype://bot/$handle${start == null ? '' : '?start=$start'}';
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
  Future<BotSentMessage> send({
    required String to,
    required String text,
    List<MessageButton> actions = const [],
  }) async {
    if (text.trim().isEmpty) {
      throw ArgumentError.value(text, 'text', 'must not be empty');
    }
    final target = await _resolveTarget(to);
    return _sendText(
      target.conversationId,
      text,
      groupId: target.groupId,
      groupName: target.groupName,
      actions: actions,
    );
  }

  /// Puts [emoji] on the message [targetMessageId] (`type: reaction`, the
  /// app's wire format, spec 2026-11-07-message-reactions). [to] addresses
  /// the conversation exactly like [send]'s `to`. An empty [emoji] removes
  /// the bot's reaction (see [removeReaction]); otherwise it must be ONE
  /// emoji ([isValidReactionEmoji]). Invalid values throw [ArgumentError]
  /// before anything is resolved or sent.
  Future<void> sendReaction({
    required String to,
    required String targetMessageId,
    required String emoji,
  }) async {
    final body = _reactionBody(targetMessageId, emoji);
    final target = await _resolveTarget(to);
    await _sendReactionBody(
      target.conversationId,
      body,
      groupId: target.groupId,
      groupName: target.groupName,
    );
  }

  /// Removes the bot's reaction from [targetMessageId] (an empty emoji).
  Future<void> removeReaction({
    required String to,
    required String targetMessageId,
  }) => sendReaction(to: to, targetMessageId: targetMessageId, emoji: '');

  /// Resolves [to] (a handle or a group id, see [send]) to where a message
  /// goes, or throws [BotSendException].
  Future<({String conversationId, String? groupId, String? groupName})>
  _resolveTarget(String to) async {
    final target = to.trim();
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
      return (conversationId: identity, groupId: null, groupName: null);
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
    return (
      conversationId: target,
      groupId: target,
      groupName: _groupNames[target.toLowerCase()],
    );
  }

  // -- Channels ---------------------------------------------------------------

  /// Publishes [text] as a `text` post in [channel] (a channel id or a
  /// `CH-XXXX-XXXX` handle) and returns the post id.
  ///
  /// The bot must be the channel's owner, admin or publisher; WHO adds it is
  /// the channel owner's decision in the app, and the server is the only
  /// authority on it (role, suspension, daily bot limit). Refusals throw
  /// [BotSendException] carrying the server's code: 403 (not allowed, or
  /// [channelSuspendedCode]), 404 (unknown channel), 429
  /// ([botPostLimitCode]). Network and 5xx errors are rethrown unchanged:
  /// they mean "try again later", not "never".
  ///
  /// Channel posts are public plaintext (no E2E fan-out), so unlike [send]
  /// this needs no hub connection.
  Future<String> postToChannel(String channel, String text) async {
    final target = channel.trim();
    if (target.isEmpty) {
      throw ArgumentError.value(channel, 'channel', 'must not be empty');
    }
    if (text.trim().isEmpty) {
      throw ArgumentError.value(text, 'text', 'must not be empty');
    }
    if (text.length > channelPostMaxChars) {
      // Refused here rather than split: every post counts against the
      // server's daily bot limit, so silently turning one call into several
      // posts would burn it.
      throw ArgumentError.value(
        text.length,
        'text',
        'at most $channelPostMaxChars characters',
      );
    }
    try {
      // Always resolved, also for an id: one GET normalises a handle or an
      // id in any case to the canonical id the post route expects, and a
      // typo fails as a clean 404 before anything is written.
      final info = await _api.getChannel(target);
      // Client-generated: the server treats a repeated postId as the same
      // post (idempotent, not counted twice against the bot limit), so a
      // caller may safely retry after a lost response.
      final postId = _uuidV4();
      await _api.createChannelPost(
        info.channelId,
        postId: postId,
        kind: 'text',
        body: text,
      );
      return postId;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 403 || status == 404 || status == 429) {
        final code = parseErrorCode(e.response?.data);
        throw BotSendException(
          switch (status) {
            404 => 'Unknown channel $target.',
            429 => 'Bot post limit reached in channel $target.',
            _ when code == channelSuspendedCode =>
              'Channel $target is suspended.',
            _ => 'The bot may not post in channel $target.',
          },
          code: code,
          statusCode: status,
        );
      }
      rethrow;
    }
  }

  Future<void> close() async {
    await _subscription?.cancel();
    for (final s in _hintSubscriptions) {
      await s.cancel();
    }
    _signalR.close();
    await _crypto;
    await Future.wait(
      _pendingActions,
    ).timeout(const Duration(seconds: 10), onTimeout: () => const []);
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
                      conversationId:
                          route?.conversationId ?? groupId ?? identity,
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
    if (payload['type'] == reactionType) {
      await _receiveReaction(
        payload,
        route: route,
        messageId: messageId,
        ackSenderId: senderId,
        groupId: groupId,
      );
      return;
    }
    // Text, media (`text` + `media` object) and, when asked for, inline
    // files. Other types (also `edit`: a bot keeps no history to edit, and
    // `delete`) are acknowledged and ignored.
    final type = payload['type'] ?? 'text';
    BotAttachment? attachment;
    var body = payload['body'] as String;
    if ((type == 'text' || type == 'media') && payload['media'] != null) {
      // An invalid `media` object leaves the fallback text, never drops the
      // message (contract section 3).
      attachment = BotAttachment.fromMedia(payload['media'], _fetchMedia);
    } else if (type == 'file' && _receiveFiles) {
      attachment = BotAttachment.fromInlineBody(body);
      if (attachment == null) {
        if (_reportedFailures.add(messageId)) {
          _log('Dropped invalid inline file $messageId from $senderId');
        }
        await _ack(senderId, messageId);
        return;
      }
      body = attachment.caption ?? '';
    } else if (type != 'text') {
      await _ack(senderId, messageId);
      return;
    }
    final groupName = payload['groupName'] as String?;
    final message = BotMessage._(
      this,
      id: messageId,
      text: body,
      senderId: route.senderIdentityId,
      conversationId: route.conversationId,
      isGroup: groupId != null,
      textMentionsBot: mentionsBot(
        body,
        handle: handle,
        displayName: displayName,
      ),
      ackSenderId: senderId,
      groupId: groupId,
      groupName: groupName,
      mentions: parseMentions(payload['mentions']),
      replyTo: BotReplyRef.parse(payload['replyTo']),
      action: parseActionRef(payload['action']),
      attachment: attachment,
    );
    // In groups the bot speaks only when addressed: mentioned, or replied
    // to (which a button press always is). Everything else is acknowledged
    // and ignored.
    if (groupId != null && !message.addressed) {
      await _ack(senderId, messageId);
      return;
    }
    if (groupId != null && groupName != null && groupName.isNotEmpty) {
      _groupNames[groupId.toLowerCase()] = groupName;
    }

    final actionHandler = _actionHandler;
    final action = message.action;
    if (actionHandler != null &&
        action != null &&
        await _isOwnButtonMessage(action.messageId)) {
      // Not chained to _conversations on purpose, see [onAction].
      late final Future<void> pending;
      pending = _handle(
        message,
        actionHandler,
        typing: false,
      ).whenComplete(() => _pendingActions.remove(pending));
      _pendingActions.add(pending);
      return;
    }

    final tail = _conversations[message.conversationId] ?? Future.value();
    late final Future<void> next;
    next = tail.then((_) => _handle(message, _handler!)).whenComplete(() {
      // Drop finished chains so the map does not grow with every peer ever.
      if (_conversations[message.conversationId] == next) {
        _conversations.remove(message.conversationId);
      }
    });
    _conversations[message.conversationId] = next;
  }

  /// A decrypted `type: reaction`: to the handler (see [onReaction]) or
  /// acknowledged and dropped.
  Future<void> _receiveReaction(
    Map<String, dynamic> payload, {
    required InboundRoute route,
    required String messageId,
    required String ackSenderId,
    required String? groupId,
  }) async {
    final handler = _reactionHandler;
    final reaction = handler == null
        ? null
        : ReactionPayload.decode(payload['body']);
    if (handler == null || reaction == null) {
      await _ack(ackSenderId, messageId);
      return;
    }
    final sent = await _sentText(reaction.targetId);
    // Only a message of THIS conversation counts as ours: a reaction naming
    // the id of a message the bot sent elsewhere learns nothing about it.
    final own =
        sent != null &&
        sent.conversationId.toLowerCase() == route.conversationId.toLowerCase();
    if (groupId != null && !own) {
      await _ack(ackSenderId, messageId);
      return;
    }
    final event = BotReaction(
      id: messageId,
      targetId: reaction.targetId,
      emoji: reaction.emoji,
      senderId: route.senderIdentityId,
      conversationId: route.conversationId,
      isGroup: groupId != null,
      groupId: groupId,
      targetIsOwn: own,
      targetText: own ? sent.text : null,
    );
    final key = route.conversationId;
    final tail = _conversations[key] ?? Future.value();
    late final Future<void> next;
    next = tail
        .then((_) async {
          try {
            await handler(event);
          } catch (error, stack) {
            _log('Reaction handler failed for $messageId: $error\n$stack');
          }
          await _ack(ackSenderId, messageId);
        })
        .whenComplete(() {
          if (_conversations[key] == next) _conversations.remove(key);
        });
    _conversations[key] = next;
  }

  static String _sentTextKey(String messageId) =>
      'sent-text:${messageId.toLowerCase()}';

  /// What the bot remembers of a message it sent (see [onReaction]).
  Future<({String conversationId, String text})?> _sentText(
    String messageId,
  ) async {
    final row = await (_db.select(
      _db.backupState,
    )..where((r) => r.key.equals(_sentTextKey(messageId)))).getSingleOrNull();
    if (row == null) return null;
    try {
      final json = jsonDecode(row.value) as Map<String, dynamic>;
      return (conversationId: json['c'] as String, text: json['t'] as String);
    } catch (_) {
      return null;
    }
  }

  var _rememberedSince = 0;

  /// Remembers the start of a sent message for reactions, and keeps only
  /// the newest [rememberedSentMessages] (pruned every 50 sends).
  Future<void> _rememberSent(
    String messageId,
    String conversationId,
    String text,
  ) async {
    if (_reactionHandler == null) return;
    final short = text.runes.length <= reactionTargetChars
        ? text
        : String.fromCharCodes(text.runes.take(reactionTargetChars));
    await _db
        .into(_db.backupState)
        .insertOnConflictUpdate(
          BackupStateCompanion.insert(
            key: _sentTextKey(messageId),
            value: jsonEncode({
              'c': conversationId,
              't': short,
              'at': DateTime.now().millisecondsSinceEpoch,
            }),
          ),
        );
    if (++_rememberedSince < 50) return;
    _rememberedSince = 0;
    final rows = await (_db.select(
      _db.backupState,
    )..where((r) => r.key.like('sent-text:%'))).get();
    if (rows.length <= rememberedSentMessages) return;
    int at(BackupStateData row) {
      try {
        return (jsonDecode(row.value) as Map<String, dynamic>)['at'] as int;
      } catch (_) {
        return 0;
      }
    }

    rows.sort((a, b) => at(a).compareTo(at(b)));
    final drop = [
      for (final row in rows.take(rows.length - rememberedSentMessages))
        row.key,
    ];
    await (_db.delete(_db.backupState)..where((r) => r.key.isIn(drop))).go();
  }

  /// GET /media/{id} for [BotAttachment]: the encrypted stream. Outside the
  /// crypto queue: a download never touches ratchet state.
  Future<MediaDownload> _fetchMedia(String mediaId) =>
      _api.downloadMedia(mediaId);

  Future<bool> _isOwnButtonMessage(String messageId) async {
    final id = messageId.toLowerCase();
    if (_sentWithActions.contains(id)) return true;
    final row = await (_db.select(
      _db.backupState,
    )..where((r) => r.key.equals('sent-actions:$id'))).getSingleOrNull();
    if (row == null) return false;
    _sentWithActions.add(id);
    return true;
  }

  Future<void> _handle(
    BotMessage message,
    BotMessageHandler handler, {
    bool typing = true,
  }) async {
    // The app shows "typing…" for a few seconds per signal, so repeat it
    // while a slow backend is thinking. A button press does not: its handler
    // is usually quick, and the conversation's own handler already types.
    void sendTyping() => unawaited(
      _signalR.sendTypingIndicator(message.conversationId).catchError((_) {}),
    );
    if (typing) sendTyping();
    final timer = typing
        ? Timer.periodic(const Duration(seconds: 4), (_) => sendTyping())
        : null;
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
      await handler(message);
    } catch (error, stack) {
      _log('Handler failed for message ${message.id}: $error\n$stack');
      try {
        await message.reply('Sorry, something went wrong. Please try again.');
      } catch (e) {
        _log('Could not send the apology either: $e');
      }
    } finally {
      timer?.cancel();
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

  /// Refuses buttons receivers would drop, so a bug shows up at the sender
  /// instead of as silently missing buttons.
  static void _checkActions(List<MessageButton> actions) {
    if (actions.length > maxActions) {
      throw ArgumentError.value(actions, 'actions', 'at most $maxActions');
    }
    final ids = <String>{};
    for (final a in actions) {
      if (!a.isValid || !ids.add(a.id)) {
        throw ArgumentError.value(a, 'actions', 'invalid or duplicate button');
      }
    }
  }

  Future<BotSentMessage> _sendText(
    String conversationId,
    String text, {
    String? groupId,
    String? groupName,
    List<MessageButton> actions = const [],
    BotReplyRef? replyTo,
  }) async {
    _checkActions(actions);
    final messageId = _uuidV4();
    if (actions.isNotEmpty) {
      // Recorded BEFORE sending: a fast press could otherwise arrive before
      // the id is known and land in the (possibly blocked) conversation queue.
      _sentWithActions.add(messageId);
      await _db
          .into(_db.backupState)
          .insertOnConflictUpdate(
            BackupStateCompanion.insert(
              key: 'sent-actions:$messageId',
              value: conversationId,
            ),
          );
    }
    await _send(
      conversationId,
      messageId,
      {
        'body': text,
        'type': 'text',
        if (replyTo != null) 'replyTo': replyTo.toJson(),
        if (actions.isNotEmpty)
          'actions': [for (final a in actions) a.toJson()],
      },
      groupId: groupId,
      groupName: groupName,
    );
    await _rememberSent(messageId, conversationId, text);
    return BotSentMessage._(
      this,
      id: messageId,
      conversationId: conversationId,
      groupId: groupId,
      groupName: groupName,
    );
  }

  Future<void> _sendEdit(
    BotSentMessage target,
    String text, {
    List<MessageButton>? actions,
  }) async {
    if (actions != null) _checkActions(actions);
    await _send(
      target.conversationId,
      // An edit is its own message on the wire (own id, own ack); `editOf`
      // names the message it changes.
      _uuidV4(),
      {
        'body': text,
        'type': 'edit',
        'editOf': target.id,
        // Key present = replace the buttons (empty = remove), absent = keep.
        if (actions != null) 'actions': [for (final a in actions) a.toJson()],
      },
      groupId: target.groupId,
      groupName: target._groupName,
    );
    // A reaction to the edited message is about its CURRENT text.
    if (await _sentText(target.id) != null) {
      await _rememberSent(target.id, target.conversationId, text);
    }
  }

  /// The reaction `body` for [targetMessageId] / [emoji] ('' removes), or
  /// [ArgumentError] for values a receiver would drop.
  String _reactionBody(String targetMessageId, String emoji) {
    if (targetMessageId.trim().isEmpty ||
        targetMessageId.length > maxReactionTargetLength) {
      throw ArgumentError.value(
        targetMessageId,
        'targetMessageId',
        'must be 1..$maxReactionTargetLength characters',
      );
    }
    if (emoji.isNotEmpty && !isValidReactionEmoji(emoji)) {
      throw ArgumentError.value(emoji, 'emoji', 'must be one emoji or empty');
    }
    return ReactionPayload(targetId: targetMessageId, emoji: emoji).encode();
  }

  /// A reaction is its own message on the wire (own id, own ack); receivers
  /// keep the newest one per sender by createdAt, which [_send] sets.
  Future<void> _sendReactionBody(
    String conversationId,
    String body, {
    String? groupId,
    String? groupName,
  }) => _send(
    conversationId,
    _uuidV4(),
    {'type': reactionType, 'body': body},
    groupId: groupId,
    groupName: groupName,
  );

  /// Encrypts and sends one payload; [content] holds the type-specific keys.
  Future<void> _send(
    String conversationId,
    String messageId,
    Map<String, dynamic> content, {
    String? groupId,
    String? groupName,
  }) async {
    final payload = jsonEncode({
      'v': 1,
      'id': messageId,
      ...content,
      'groupId': groupId,
      'groupName': groupName,
      // Multi-device: names the direct conversation for a sender's own other
      // devices; required in every direct payload.
      if (groupId == null) 'to': conversationId,
      // Also the edit ordering key: receivers apply an edit only when its
      // createdAt is newer than the last applied one.
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
