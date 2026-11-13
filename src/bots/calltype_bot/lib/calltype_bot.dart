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
import 'package:calltype_core/media/media_info.dart';
import 'package:calltype_core/network/media_api.dart';
import 'package:calltype_core/messaging/agent_payload.dart';
import 'package:calltype_core/messaging/group_topic.dart';
import 'package:calltype_core/messaging/poll.dart';
import 'package:calltype_core/messaging/reaction.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/network/bot_dtos.dart';
import 'package:calltype_core/network/channel_dtos.dart' show parseErrorCode;
import 'package:calltype_core/network/hub_transport.dart';
import 'package:calltype_core/network/signalr_client.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:calltype_core/storage/drift_protocol_store.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import 'src/ack_reactions.dart';
import 'src/attachment.dart';
import 'src/encrypted_file_store.dart';
import 'src/group_info.dart';
import 'src/media_tools.dart';
import 'src/media_upload.dart';
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
export 'package:calltype_core/messaging/group_topic.dart'
    show GroupTopicPayload, groupTopicType, maxGroupTopicLength;
export 'package:calltype_core/messaging/pin.dart' show pinType;
export 'package:calltype_core/messaging/poll.dart'
    show PollPayload, pollKey, pollVoteType;
export 'package:calltype_core/network/bot_dtos.dart' show BotCommand;
export 'package:calltype_core/network/group_dtos.dart'
    show BotTalkMode, BotTalkSettings, GroupTopicRecord, MuteMode, MuteSetting;
export 'src/ack_reactions.dart';
export 'src/bot_talk.dart';
export 'src/attachment.dart';
export 'src/encrypted_file_store.dart';
export 'src/inbound_policy.dart';
export 'src/group_info.dart';
export 'src/media_tools.dart';
export 'src/media_upload.dart';
export 'src/ws_hub_transport.dart';

typedef BotMessageHandler = Future<void> Function(BotMessage message);

/// Handles one emoji reaction, see [CallTypeBot.onReaction].
typedef BotReactionHandler = Future<void> Function(BotReaction reaction);

/// Second-chance pre-decrypt check for a sender [allowSender] refused, when
/// the server says the message belongs to group [groupId]. See [CallTypeBot.onMessage].
typedef GroupSenderCheck =
    Future<bool> Function(String senderId, String groupId);

/// Receives a group message as CONTEXT (spec 2026-11-13-group-topics row
/// 19), see [CallTypeBot.onContext]. Never a turn: the handler must not
/// reply, react or run anything because of it.
typedef BotContextHandler = Future<void> Function(BotMessage message);

/// Whether the bridge serves group [groupId] (its own rule, e.g. an owner
/// of the bot is a member). See `servesGroup` in [CallTypeBot.onMessage].
typedef GroupServesCheck = Future<bool> Function(String groupId);

/// A group topic as the bot stored it (spec 2026-11-13-group-topics,
/// receiver rules): validated against the server's record, newest version
/// wins. [topic] is '' when the admins cleared it.
class BotGroupTopic {
  const BotGroupTopic({
    required this.topic,
    required this.version,
    required this.setBy,
  });

  final String topic;
  final int version;

  /// Identity id (lower-case) of the admin who set it.
  final String setBy;

  @override
  String toString() =>
      'BotGroupTopic(v$version, ${topic.length} characters)';
}

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
    this.poll,
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

  /// The poll this message carries (spec 2026-11-08-chat-extras), or null.
  /// [text] is then the poll's plain-text fallback (question and options),
  /// which is what a bot that ignores this field works with. Votes
  /// (`poll-vote`) and pins (`pin`) never reach the handler.
  final PollPayload? poll;

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

  /// In a group the bot handles only addressed messages: a mention, a
  /// reply to it, or (group setting "Reply without mention", T4) any
  /// message of a human member, see [addressedByGroupSetting].
  bool get addressed => mentionsBot || repliesToBot || _addressedBySetting;

  /// Addressed only because the group's `replyWithoutMention` is on and the
  /// sender is a human member (spec 2026-11-13-group-topics row 20). Bots
  /// still need a mention or a reply.
  bool get addressedByGroupSetting => _addressedBySetting;
  var _addressedBySetting = false;

  /// Delivered through [CallTypeBot.onContext]: something the group said
  /// that does not start a turn. Never reply to it or react on it.
  bool get isContext => _isContext;
  var _isContext = false;

  /// The group's topic as set by its admins (spec 2026-11-13-group-topics
  /// T2), or null when there is none (1:1, never set, cleared). Text from
  /// the admins: a brief, but never a reason to bypass the bot's own rules.
  String? get groupTopic => _groupTopic;
  String? _groupTopic;

  /// Version of the stored topic (also of a cleared one), or null when the
  /// bot has none for this group. Changes whenever the admins change it.
  int? get groupTopicVersion => _groupTopicVersion;
  int? _groupTopicVersion;

  /// The sender's handle and display name from the group's member list
  /// (null in 1:1 or when unknown), e.g. to label context lines.
  String? get senderHandle => _senderHandle;
  String? _senderHandle;
  String? get senderDisplayName => _senderDisplayName;
  String? _senderDisplayName;

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
  }) async {
    final sent = await _bot._sendText(
      conversationId,
      text,
      groupId: isGroup ? conversationId : null,
      groupName: _groupName,
      actions: actions,
      replyTo: isGroup
          ? BotReplyRef(
              id: id,
              senderId: senderId,
              preview: _preview(this.text),
            )
          : null,
    );
    _replied = true;
    return sent;
  }

  /// A [reply] or [replyFile] of this turn went out (see [AckReactions]).
  bool get replied => _replied;
  var _replied = false;

  /// The receipt reaction was sent (or tried), see [accept].
  bool get accepted => _receipt != null;
  Future<void>? _receipt;

  /// The emoji the turn ends with, instead of the [AckReactions] default
  /// (a model's `[react:EMOJI]`); '' removes the bot's reaction. Applied by
  /// the runtime after the handler returns, also without [AckReactions].
  /// An invalid value is logged and ignored. A failed turn still ends ❌.
  String? finalReaction;

  /// The turn failed although the handler returned normally (it posted its
  /// own error text): the final reaction is [AckReactions.failed].
  void markFailed() => _failed = true;
  var _failed = false;

  /// Puts the [AckReactions.received] reaction on this message (once). The
  /// runtime calls it before the handler, or the handler does with
  /// [AckReactions.manual]. No-op without acknowledgement reactions. Never
  /// throws: a failed send is logged and the turn goes on.
  Future<void> accept() {
    final config = _bot._ackReactions;
    if (config == null) return Future.value();
    return _receipt ??= Future.sync(() => react(config.received)).catchError((
      Object e,
    ) {
      _bot._log('Receipt reaction on message $id failed: $e');
    });
  }

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

  /// Sends the file at [path] back into this conversation, quoting this
  /// message in a group like [reply]. Options as in [CallTypeBot.sendFile].
  Future<BotSentMessage> replyFile(
    String path, {
    MediaKind? kind,
    String? caption,
    String? name,
    String? mime,
    int? durationMs,
    Uint8List? waveform,
    Uint8List? thumbnail,
    bool inlineSmallImages = true,
  }) async {
    final sent = await _bot._sendFile(
      conversationId,
      path,
      kind: kind,
      caption: caption,
      name: name,
      mime: mime,
      durationMs: durationMs,
      waveform: waveform,
      thumbnail: thumbnail,
      inlineSmallImages: inlineSmallImages,
      groupId: isGroup ? conversationId : null,
      groupName: _groupName,
      replyTo: isGroup
          ? BotReplyRef(id: id, senderId: senderId, preview: _preview(text))
          : null,
    );
    _replied = true;
    return sent;
  }
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
    this._keys,
    this._preKeyCheckInterval,
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
  final KeyManager _keys;

  /// How often [replenishPreKeys] runs after [onMessage]; zero = never.
  final Duration _preKeyCheckInterval;
  Timer? _preKeyTimer;

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

  /// Acknowledgement reactions, see [onMessage]; null = off.
  AckReactions? _ackReactions;

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
  GroupServesCheck? _servesGroup;
  BotContextHandler? _contextHandler;

  /// Stored group topics by group id (lower-case); mirrors the
  /// `group-topic:<id>` rows of `backupState`, loaded lazily.
  final _topics = <String, BotGroupTopic?>{};
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
    Duration preKeyCheckInterval = const Duration(minutes: 30),
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

    final sessions = SessionManager(store: DriftProtocolStore(db), keyManager: keys);
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
      keys,
      preKeyCheckInterval,
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
  ///
  /// [ackReactions] (spec 2026-11-11-bot-ack-reactions): react 👀 on every
  /// accepted message before its turn and replace it with the turn's final
  /// emoji (✅ replied, 👍 nothing sent, ❌ failed). Null = off. Dropped
  /// messages (refused senders, unaddressed group messages, control
  /// messages, reactions) never get one.
  ///
  /// [servesGroup] (spec 2026-11-13-group-topics row 21): the bridge's rule
  /// for "this is a group I work for" (e.g. an owner is a member). When it
  /// says yes, a group message from a sender [allowSender] and
  /// [allowGroupSender] refused is still DECRYPTED, but it can only update
  /// the group topic or reach [onContext]; it never starts a turn. Without
  /// it refused senders stay dropped blind, as before.
  Future<void> onMessage(
    BotMessageHandler handler, {
    bool Function(String senderId)? allowSender,
    GroupSenderCheck? allowGroupSender,
    GroupServesCheck? servesGroup,
    bool receiveFiles = false,
    AckReactions? ackReactions,
  }) async {
    _handler = handler;
    _ackReactions = ackReactions;
    _receiveFiles = receiveFiles;
    _allowSender = allowSender;
    _allowGroupSender = allowGroupSender;
    _servesGroup = servesGroup;
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
    if (_preKeyCheckInterval > Duration.zero && _preKeyTimer == null) {
      unawaited(replenishPreKeys());
      _preKeyTimer = Timer.periodic(
        _preKeyCheckInterval,
        (_) => unawaited(replenishPreKeys()),
      );
    }
  }

  /// Publishes who may message this bot through the server (spec
  /// 2026-11-09-bot-access A1/A3): [owners] (handles) only, or everybody
  /// when [ownersOnly] is false. Throws on a server error; an old server
  /// without the endpoint answers 404 (see [isNotFound]).
  Future<List<String>> setInboundPolicy({
    required bool ownersOnly,
    Iterable<String> owners = const [],
  }) => _api.setBotPolicy(
    deviceId,
    mode: ownersOnly ? 'owners' : 'open',
    owners: ownersOnly ? owners.toList() : const [],
  );

  /// True when [error] is an HTTP 404 (an endpoint an old server lacks).
  static bool isNotFound(Object error) =>
      error is DioException && error.response?.statusCode == 404;

  /// Below this many one-time pre-keys on the server, [replenishPreKeys]
  /// tops the pool up to [preKeyTarget].
  static const preKeyThreshold = 20;
  static const preKeyTarget = 100;
  var _preKeysUnsupported = false;

  /// Tops up this bot's one-time pre-keys on the server (spec
  /// 2026-11-09-bot-access A6). Returns how many were uploaded (0 = pool
  /// still full enough), or null when the check failed (logged).
  ///
  /// WHY a bot needs this: every new peer device consumes one key, and the
  /// registration batch of 100 is never refilled otherwise. Without keys
  /// sessions still work (signed pre-key only) but lose the extra forward
  /// secrecy of the first message.
  Future<int?> replenishPreKeys() async {
    if (_preKeysUnsupported) return null;
    try {
      final count = await _api.getOneTimePreKeyCount(deviceId);
      if (count >= preKeyThreshold) return 0;
      // In the crypto queue: the pre-key list is read-modify-write in the
      // store, and a decrypt consuming a key at the same time would lose
      // one of the two writes.
      final created = await _inCrypto(
        () => _keys.createOneTimePreKeys(preKeyTarget - count),
      );
      await _api.uploadOneTimePreKeys(deviceId, [
        for (final k in created)
          {'keyId': k['keyId'], 'publicKey': k['publicKey']},
      ]);
      _log('Uploaded ${created.length} one-time pre-keys (server had $count).');
      return created.length;
    } catch (e) {
      if (isNotFound(e)) {
        // Old server: nothing to replenish into; stop asking.
        _preKeysUnsupported = true;
        _preKeyTimer?.cancel();
        _log('Server has no one-time pre-key endpoint; not replenishing.');
      } else {
        _log('One-time pre-key check failed: $e');
      }
      return null;
    }
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

  /// Handles group messages that do not start a turn (spec
  /// 2026-11-13-group-topics row 19, "Bots read everything"). Set it
  /// BEFORE [onMessage]. Only when the group's `botsReadAll` is on and the
  /// `servesGroup` callback of [onMessage] says yes: unaddressed text and
  /// media messages, and group messages of senders the admission checks
  /// refused, arrive here with [BotMessage.isContext] set.
  ///
  /// Runs in the conversation's queue, without typing indicator, ack
  /// reaction, actions or buttons, and is acknowledged after the handler
  /// (a failing handler is only logged). Messages of this bot never come
  /// here. Without a handler such messages are acknowledged and dropped.
  void onContext(BotContextHandler handler) => _contextHandler = handler;

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
      topic: details.topic,
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

  /// Sends the file at [path] to [to] (a handle or a group id, as [send]).
  ///
  /// Encrypted media (contract 2026-11-07-encrypted-media): the file is
  /// encrypted with a fresh key in the app's chunk format (calltype_core
  /// `MediaCipher`), streamed from disk to the media relay, and the message
  /// carries the key (`type: text` + English fallback body + `media`).
  /// Small images (JPEG, PNG, GIF, WebP up to 256 KiB) go inline as an old
  /// `type: file` message instead, like the app's photos, so they show
  /// without a download tap; [inlineSmallImages] false forces the media
  /// path.
  ///
  /// [kind] defaults to what the name / MIME type say ([MediaKind.voice]
  /// only when asked for). A voice message is converted with [mediaTools]
  /// (ffmpeg) to AAC-LC mono `.m4a`, the format the app records and plays
  /// everywhere; without ffmpeg the file goes as it is (MP3 and M4A play on
  /// every client). Duration, waveform, dimensions and a thumbnail are
  /// added when ffmpeg is there and the caller did not pass them.
  ///
  /// Throws [ArgumentError] for a missing file, [BotMediaTooLarge] above
  /// [maxFileBytes] (default: the client cap of 5 GiB - 1 MiB),
  /// [BotMediaRefused] when the server refuses (size cap, quota) and
  /// [BotSendException] for an unknown target.
  Future<BotSentMessage> sendFile({
    required String to,
    required String path,
    MediaKind? kind,
    String? caption,
    String? name,
    String? mime,
    int? durationMs,
    Uint8List? waveform,
    Uint8List? thumbnail,
    bool inlineSmallImages = true,
  }) async {
    if (!await File(path).exists()) {
      throw ArgumentError.value(path, 'path', 'no such file');
    }
    final target = await _resolveTarget(to);
    return _sendFile(
      target.conversationId,
      path,
      kind: kind,
      caption: caption,
      name: name,
      mime: mime,
      durationMs: durationMs,
      waveform: waveform,
      thumbnail: thumbnail,
      inlineSmallImages: inlineSmallImages,
      groupId: target.groupId,
      groupName: target.groupName,
    );
  }

  /// ffmpeg / ffprobe for outgoing media (voice conversion, waveform,
  /// thumbnails). Defaults to the binaries on PATH; replace it to point at
  /// other binaries or with [BotMediaTools.disabled].
  BotMediaTools mediaTools = BotMediaTools();

  /// Largest file [sendFile] uploads (plaintext bytes).
  int maxFileBytes = mediaMaxBytes;

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
    _preKeyTimer?.cancel();
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
    // Refused for turns, but maybe still worth reading (spec
    // 2026-11-13-group-topics row 21): in a group the bridge serves, the
    // message may set the topic (the admin need not be an owner) or be
    // context. Never for the bot itself.
    var contextOnly = false;
    final serves = _servesGroup;
    if (!allowed &&
        groupId != null &&
        serves != null &&
        identity != deviceId.toLowerCase()) {
      try {
        contextOnly = await serves(groupId);
      } catch (e) {
        contextOnly = false; // fail closed, like allowGroupSender
      }
    }
    if (!allowed && !contextOnly) {
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
    if (payload['type'] == groupTopicType) {
      _receiveTopic(
        payload,
        route: route,
        messageId: messageId,
        ackSenderId: senderId,
        groupId: groupId,
      );
      return;
    }
    // A refused sender's reaction or inline file is never context.
    if (contextOnly &&
        (payload['type'] == reactionType || payload['type'] == 'file')) {
      await _ack(senderId, messageId);
      return;
    }
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
    // files. Other types (also `edit`: a bot keeps no history to edit,
    // `delete`, and the chat extras `pin` / `poll-vote`, spec 2026-11-08)
    // are acknowledged and ignored.
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
      // A poll is `text` + fallback + `poll`; media wins, like in the app.
      poll: payload['media'] == null
          ? PollPayload.tryParse(payload[pollKey])
          : null,
      attachment: attachment,
    );
    if (contextOnly) {
      // A refused sender: context at most, never a turn (even when it
      // mentions the bot).
      _queue(
        message.conversationId,
        () => _contextOrDrop(message, alreadyServed: true),
      );
      return;
    }
    // In groups the bot speaks only when addressed: mentioned, or replied
    // to (which a button press always is). The rest may still be addressed
    // by the group's "Reply without mention" or become context; both need
    // the group's settings, so that is decided in the conversation queue
    // (a REST lookup there delays only this conversation). Without either
    // it is acknowledged and ignored, as before.
    if (groupId != null && !message.addressed) {
      _queue(message.conversationId, () => _unaddressed(message));
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

    _queue(message.conversationId, () => _handle(message, _handler!));
  }

  /// Appends [task] to the handler queue of [conversationId].
  void _queue(String conversationId, Future<void> Function() task) {
    final tail = _conversations[conversationId] ?? Future.value();
    late final Future<void> next;
    next = tail.then((_) => task()).whenComplete(() {
      // Drop finished chains so the map does not grow with every peer ever.
      if (_conversations[conversationId] == next) {
        _conversations.remove(conversationId);
      }
    });
    _conversations[conversationId] = next;
  }

  /// The group's info with a sender the cached list does not know yet
  /// re-read once; null when it cannot be read.
  Future<GroupInfo?> _groupWith(String groupId, String senderId) async {
    try {
      var info = await group(groupId);
      if (!info.isMember(senderId)) {
        // A sender the cached list does not know joined after we cached.
        invalidateGroups(groupId);
        info = await group(groupId);
      }
      return info;
    } catch (_) {
      return null;
    }
  }

  /// Fills the group fields of [message] (sender profile, stored topic).
  Future<void> _decorate(BotMessage message, GroupInfo? info) async {
    final groupId = message.groupId;
    if (groupId == null) return;
    final member = info?.member(message.senderId);
    message._senderIsBot = member?.isBot;
    message._senderHandle = member?.handle;
    message._senderDisplayName = member?.displayName;
    final topic = await groupTopic(groupId);
    message._groupTopic = topic == null || topic.topic.isEmpty
        ? null
        : topic.topic;
    message._groupTopicVersion = topic?.version;
  }

  /// An unaddressed group message of an admitted sender: a turn when the
  /// group's `replyWithoutMention` is on and the sender is a HUMAN member
  /// (T4; a bot sender still needs a mention, so bots never start talking
  /// to each other through it), else context or dropped.
  Future<void> _unaddressed(BotMessage message) async {
    final info = await _groupWith(message.groupId!, message.senderId);
    final member = info?.member(message.senderId);
    if (info != null &&
        info.botTalk.replyWithoutMention &&
        member != null &&
        !member.isBot &&
        message.senderId.toLowerCase() != deviceId.toLowerCase()) {
      message._addressedBySetting = true;
      final name = message._groupName;
      if (name != null && name.isNotEmpty) {
        _groupNames[message.groupId!.toLowerCase()] = name;
      }
      await _handle(message, _handler!);
      return;
    }
    await _contextOrDrop(message, info: info);
  }

  /// Hands [message] to [onContext] when the group reads along
  /// (`botsReadAll`) and the bridge serves it, then acknowledges it.
  Future<void> _contextOrDrop(
    BotMessage message, {
    GroupInfo? info,
    bool alreadyServed = false,
  }) async {
    try {
      final handler = _contextHandler;
      final serves = _servesGroup;
      final groupId = message.groupId;
      if (handler == null ||
          serves == null ||
          groupId == null ||
          message.action != null ||
          message.senderId.toLowerCase() == deviceId.toLowerCase()) {
        return;
      }
      info ??= await _groupWith(groupId, message.senderId);
      if (info == null || !info.botTalk.botsReadAll) return;
      if (!alreadyServed) {
        try {
          if (!await serves(groupId)) return;
        } catch (_) {
          return;
        }
      }
      message._isContext = true;
      await _decorate(message, info);
      try {
        await handler(message);
      } catch (error, stack) {
        _log('Context handler failed for message ${message.id}: $error\n$stack');
      }
    } finally {
      await _ack(message._ackSenderId, message.id);
    }
  }

  static String _topicKey(String groupId) =>
      'group-topic:${groupId.toLowerCase()}';

  /// The stored topic of [groupId] (spec 2026-11-13-group-topics T2), or
  /// null when the bot never received a valid one. A cleared topic has an
  /// empty [BotGroupTopic.topic].
  Future<BotGroupTopic?> groupTopic(String groupId) async {
    final key = groupId.toLowerCase();
    if (_topics.containsKey(key)) return _topics[key];
    BotGroupTopic? topic;
    final row = await (_db.select(
      _db.backupState,
    )..where((r) => r.key.equals(_topicKey(key)))).getSingleOrNull();
    if (row != null) {
      try {
        final json = jsonDecode(row.value) as Map<String, dynamic>;
        topic = BotGroupTopic(
          topic: json['topic'] as String,
          version: json['version'] as int,
          setBy: json['setBy'] as String,
        );
      } catch (_) {
        topic = null; // a damaged row counts as none; the next change heals it
      }
    }
    return _topics[key] = topic;
  }

  /// A decrypted `group-topic` (spec "Wire shapes", receiver rules 1-5):
  /// in the group's queue, so a message right after it already sees it.
  /// Every refusal is acknowledged and dropped; a network error too, since
  /// bots handle a message at most once (the next change re-sends).
  /// WHY the text never reaches the log: it is the group's content.
  void _receiveTopic(
    Map<String, dynamic> payload, {
    required InboundRoute route,
    required String messageId,
    required String ackSenderId,
    required String? groupId,
  }) {
    final decoded = GroupTopicPayload.decode(payload['body']);
    if (groupId == null || decoded == null) {
      unawaited(_ack(ackSenderId, messageId));
      return;
    }
    _queue(route.conversationId, () async {
      try {
        // Never the cache: the record must be the server's current one.
        invalidateGroups(groupId);
        final GroupInfo info;
        try {
          info = await group(groupId);
        } catch (e) {
          _log('Group topic $messageId for $groupId not verified: $e');
          return;
        }
        final record = info.topic;
        if (record == null ||
            !record.matches(decoded.version, route.senderIdentityId)) {
          _log('Group topic $messageId for $groupId refused: not recorded.');
          return;
        }
        final stored = await groupTopic(groupId);
        if (stored != null && decoded.version <= stored.version) return;
        final topic = BotGroupTopic(
          topic: decoded.topic,
          version: decoded.version,
          setBy: route.senderIdentityId.toLowerCase(),
        );
        await _db
            .into(_db.backupState)
            .insertOnConflictUpdate(
              BackupStateCompanion.insert(
                key: _topicKey(groupId),
                value: jsonEncode({
                  'topic': topic.topic,
                  'version': topic.version,
                  'setBy': topic.setBy,
                }),
              ),
            );
        _topics[groupId.toLowerCase()] = topic;
        _log('Group topic of $groupId is now version ${topic.version}.');
      } finally {
        await _ack(ackSenderId, messageId);
      }
    });
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
    final ack = _ackReactions;
    if (ack != null && !ack.manual) await message.accept();
    if (typing) sendTyping();
    final timer = typing
        ? Timer.periodic(const Duration(seconds: 4), (_) => sendTyping())
        : null;
    try {
      final groupId = message.groupId;
      if (groupId != null) {
        // Outside the crypto queue on purpose: a slow REST call here only
        // delays this conversation. Unknown stays null; the handler decides
        // how to treat that.
        await _decorate(message, await _groupWith(groupId, message.senderId));
      }
      await handler(message);
    } catch (error, stack) {
      message._failed = true;
      _log('Handler failed for message ${message.id}: $error\n$stack');
      try {
        await message.reply('Sorry, something went wrong. Please try again.');
      } catch (e) {
        _log('Could not send the apology either: $e');
      }
    } finally {
      timer?.cancel();
    }
    await _finalReaction(message);
    // Ack only now: if the process dies mid-handler the server still holds
    // the message, re-delivers it, and the seen-row turns that into a plain
    // ack instead of a second backend call.
    await _ack(message._ackSenderId, message.id);
  }

  /// Replaces the receipt with the turn's final emoji (see [AckReactions]),
  /// or applies [BotMessage.finalReaction] alone when acknowledgements are
  /// off or the message was never accepted. Failures are only logged.
  Future<void> _finalReaction(BotMessage message) async {
    final ack = _ackReactions;
    var emoji = message.finalReaction;
    if (emoji != null && emoji.isNotEmpty && !isValidReactionEmoji(emoji)) {
      _log('Invalid final reaction "$emoji" for ${message.id}: ignored.');
      emoji = null;
    }
    if (ack != null && message.accepted) {
      if (message._failed) {
        emoji = ack.failed;
      } else {
        emoji ??= message._replied ? ack.answered : ack.noReply;
      }
    }
    if (emoji == null) return;
    // After the receipt (which never throws): the final emoji must be the
    // newer reaction, also with equal timestamps (arrival order).
    await message._receipt;
    if (ack != null && message.accepted && emoji == ack.received) return;
    try {
      await message.react(emoji);
    } catch (e) {
      _log('Final reaction on message ${message.id} failed: $e');
    }
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

  static const _inlineImageMimes = {
    'image/jpeg',
    'image/png',
    'image/gif',
    'image/webp',
  };

  Future<BotSentMessage> _sendFile(
    String conversationId,
    String path, {
    MediaKind? kind,
    String? caption,
    String? name,
    String? mime,
    int? durationMs,
    Uint8List? waveform,
    Uint8List? thumbnail,
    bool inlineSmallImages = true,
    String? groupId,
    String? groupName,
    BotReplyRef? replyTo,
  }) async {
    var file = File(path);
    if (!await file.exists()) {
      throw ArgumentError.value(path, 'path', 'no such file');
    }
    var fileName = name ?? file.uri.pathSegments.last;
    if (!isValidMediaName(fileName)) {
      final cleaned = fileName
          .replaceAll(
            RegExp('[/\\\\\x00-\x1f\x7f:<>"|?*\u202a-\u202e\u2066-\u2069]'),
            '_',
          )
          .replaceAll(RegExp(r'[. ]+$'), '');
      fileName = isValidMediaName(cleaned) ? cleaned : 'file';
    }
    var fileMime = normalizeMediaMime(mime, fileName);
    final fileKind = kind ?? mediaKindFor(fileName, mime: fileMime);
    var text = caption?.trim();
    if (text != null && text.isEmpty) text = null;
    int? width;
    int? height;
    Directory? temp;
    try {
      final tools = mediaTools;
      if (fileKind == MediaKind.voice) {
        if (await tools.available) {
          temp = await Directory.systemTemp.createTemp('calltype_bot_voice');
          final now = DateTime.now();
          String two(int v) => v.toString().padLeft(2, '0');
          fileName =
              'voice-${now.year}${two(now.month)}${two(now.day)}-'
              '${two(now.hour)}${two(now.minute)}${two(now.second)}.m4a';
          file = await tools.toVoiceM4a(file, '${temp.path}/$fileName');
          fileMime = 'audio/mp4';
        } else if (!const {
          'audio/mp4',
          'audio/aac',
          'audio/mpeg',
        }.contains(fileMime)) {
          _log(
            'Voice message $fileName is $fileMime and ffmpeg is missing: '
            'some clients (iOS) may not play it.',
          );
        }
        if (durationMs == null || waveform == null) {
          final analysed = await tools.analyzeAudio(file);
          durationMs ??= analysed?.durationMs;
          waveform ??= analysed?.waveform;
        }
      } else if (fileKind == MediaKind.audio && durationMs == null) {
        durationMs = (await tools.probe(file))?.durationMs;
      }
      final size = await file.length();
      if (fileKind == MediaKind.image &&
          inlineSmallImages &&
          size <= inlineFileMaxBytes &&
          _inlineImageMimes.contains(fileMime)) {
        // The app's photo path: inline, shown without a download tap.
        final inlineCaption = text == null || text.runes.length <= 1024
            ? text
            : String.fromCharCodes(text.runes.take(1024)).trimRight();
        final messageId = _uuidV4();
        await _send(
          conversationId,
          messageId,
          {
            'type': 'file',
            'body': jsonEncode({
              'name': fileName,
              'data': base64Encode(await file.readAsBytes()),
              'caption': ?inlineCaption,
            }),
            if (replyTo != null) 'replyTo': replyTo.toJson(),
          },
          groupId: groupId,
          groupName: groupName,
        );
        await _rememberSent(
          messageId,
          conversationId,
          inlineCaption ?? fileName,
        );
        return BotSentMessage._(
          this,
          id: messageId,
          conversationId: conversationId,
          groupId: groupId,
          groupName: groupName,
        );
      }
      if (fileKind == MediaKind.image || fileKind == MediaKind.video) {
        final probed = await tools.probe(file);
        width = probed?.width;
        height = probed?.height;
        if (fileKind == MediaKind.video) durationMs ??= probed?.durationMs;
        thumbnail ??= await tools.thumbnail(file);
      }
      if (text != null && text.length > 4096) {
        text = text.substring(0, 4096);
      }
      final info = await uploadMediaFile(
        _api,
        file,
        kind: fileKind,
        name: fileName,
        mime: fileMime,
        maxBytes: maxFileBytes,
        durationMs: durationMs,
        width: width,
        height: height,
        thumbnail: thumbnail,
        waveform: waveform == null || waveform.isEmpty ? null : waveform,
        caption: text,
        retryDelay: _sendRetryDelay,
      );
      final fallback = mediaFallbackText(info);
      final messageId = _uuidV4();
      // Contract M7: `text` with a fallback body for old clients plus the
      // `media` object new clients read.
      await _send(
        conversationId,
        messageId,
        {
          'type': 'text',
          'body': fallback,
          'media': info.toJson(),
          if (replyTo != null) 'replyTo': replyTo.toJson(),
        },
        groupId: groupId,
        groupName: groupName,
      );
      _log(
        'Sent ${fileKind.name} $fileName (${formatMediaSize(info.size)}) '
        'as media ${info.id}.',
      );
      await _rememberSent(messageId, conversationId, text ?? fallback);
      return BotSentMessage._(
        this,
        id: messageId,
        conversationId: conversationId,
        groupId: groupId,
        groupName: groupName,
      );
    } finally {
      if (temp != null) {
        try {
          await temp.delete(recursive: true);
        } catch (_) {}
      }
    }
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
  ///
  /// Always silent (spec 2026-11-11-bot-ack-reactions N2): the server never
  /// pushes a bot's reaction to an offline device. The generic "New message"
  /// push cannot say what arrived, and the app shows no notification for a
  /// bot's reaction anyway, so a push would only wake the phone for nothing.
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
    silent: true,
  );

  /// Encrypts and sends one payload; [content] holds the type-specific keys.
  /// [silent]: stored and delivered as usual, but never pushed to an offline
  /// device (the plain hub method on a server without silent sends).
  Future<void> _send(
    String conversationId,
    String messageId,
    Map<String, dynamic> content, {
    String? groupId,
    String? groupName,
    bool silent = false,
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
            silent: silent,
          );
        } else if (groupId == null) {
          await _signalR.sendDirectFanout(
            conversationId,
            envelopes,
            messageId: messageId,
            silent: silent,
          );
        } else {
          await _signalR.sendGroupFanout(
            groupId,
            envelopes,
            messageId: messageId,
            silent: silent,
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
