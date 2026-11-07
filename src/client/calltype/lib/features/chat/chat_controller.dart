import 'package:calltype_core/devices/device_directory.dart';
import 'package:calltype_core/devices/fanout_sender.dart';
import 'package:calltype_core/messaging/agent_payload.dart';
import 'package:calltype_core/network/signalr_client.dart' as core
    show SignalRClient;
import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Locale;

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../../l10n/app_localizations.dart';
import '../media/media_cleanup.dart';
import '../media/media_crypto.dart';
import '../media/media_message.dart';
import '../media/media_service.dart';
import 'attachment_media.dart';
import 'package:calltype_core/network/organization_api.dart';
import 'package:calltype_core/network/organization_dtos.dart';
import '../../core/crypto/group_cipher.dart';
import '../../core/crypto/session_manager.dart';
import '../../core/network/api_client.dart';
import '../../core/network/signalr_client.dart';
import '../../core/storage/database.dart';
import 'message_inbox_service.dart';
import 'attachment.dart';
import 'bot_commands.dart';

/// Handed to the chat route (`GoRouter` `extra`) by the forward dialog; the
/// route's `create:` sends it once on the freshly created controller.
class ForwardDraft {
  const ForwardDraft({required this.body, required this.type});
  final String body;
  final String type;
}

/// Local `messages.type` values that are outbox control messages, never
/// chat bubbles.
const controlTypes = ['delete', 'edit'];

/// Handed to the chat route (`GoRouter` `extra`) by the bot deep link: text
/// put into the composer, NEVER sent on its own (the user presses send).
class ComposerDraft {
  const ComposerDraft(this.text);
  final String text;
}

class ChatController extends ChangeNotifier {
  ChatController({
    required AppDatabase database,
    required SignalRClient signalRClient,
    required SessionManager sessionManager,
    required MessageInboxService inbox,
    required ApiClient apiClient,
    required this.conversationId,
    required DeviceDirectory directory,
    void Function(Set<String> required)? onStale,
    void Function(String deviceId)? onMissingOwnDevice,
    BotCommandsCache? commandsCache,
    MediaService? media,
  }) : _db = database,
       media = media ?? MediaService.instance,
       _commandsCache = commandsCache ?? BotCommandsCache.shared,
       _signalR = signalRClient,
       _sessions = sessionManager,
       _api = apiClient,
       _directory = directory,
       // Stateless apart from these references, so each chat builds its own
       // instead of sharing one through the provider tree.
       _fanout = FanoutSender(
         directory: directory,
         sessions: sessionManager,
         apiClient: apiClient,
         // Only OUR OWN listed companion that vanished is the user's business
         // (it may have deleted itself); a contact's missing device is just
         // skipped. Fire-and-forget: this runs inside the processing queue.
         // Zone.root: the call happens inside the send's db.transaction, and
         // drift binds database work to the transaction of the current zone,
         // which is closed by the time this unawaited write would run.
         onMissingDevice: (deviceId) => Zone.root.run(
           () => unawaited(
             _reportIfOwn(deviceId, directory, onMissingOwnDevice),
           ),
         ),
       ),
       _onStale = onStale {
    _subscription =
        (_db.select(_db.messages)
              ..where((m) => m.conversationId.equals(conversationId))
              // 'delete' / 'edit' rows are hidden control messages (see
              // deleteForEveryone, editMessage); they ride the outbox but
              // are not chat.
              ..where((m) => m.type.isIn(controlTypes).not())
              // rowId breaks ties: timestamps are stored with second
              // precision, so a quick answer could otherwise land ABOVE the
              // message it answers.
              ..orderBy([
                (m) => OrderingTerm.desc(m.createdAt),
                (m) => OrderingTerm.desc(m.rowId),
              ]))
            .watch()
            .listen((rows) {
              _messages = rows;
              if (!_disposed) notifyListeners();
            });
    _incoming = inbox.persistedMessages.listen((message) {
      if (message.conversationId == conversationId) _markRead();
    });
    _markRead();
    _syncBusinessInfo();
    _loadGroupMembers();
  }

  /// Backfills the local `organizationId`/`organizationName` cache for this
  /// conversation from the server, once. This is what lets the chat list
  /// badge and this screen's banner appear WITHOUT a network call on every
  /// render — see `Conversations` table doc in `calltype_core` (E05).
  Future<void> _syncBusinessInfo() async {
    final conversation = await (_db.select(
      _db.conversations,
    )..where((c) => c.id.equals(conversationId))).getSingleOrNull();
    if (conversation == null ||
        conversation.type != 'group' ||
        conversation.organizationId != null) {
      return;
    }
    try {
      final info = await _api.getGroupBusinessInfo(conversationId);
      if (!info.isBusiness || _disposed) return;
      await (_db.update(_db.conversations)
            ..where((c) => c.id.equals(conversationId)))
          .write(
            ConversationsCompanion(
              organizationId: Value(info.organizationId),
              organizationName: Value(info.organizationName),
            ),
          );
    } catch (_) {
      // Best-effort cache warm-up; the banner simply won't show yet.
    }
  }

  List<GroupMemberInfo> _groupMembers = [];

  /// Members of this conversation when it is a group (empty for direct chats
  /// and until the one-time load finishes); feeds @mentions and sender names.
  List<GroupMemberInfo> get groupMembers => List.unmodifiable(_groupMembers);

  /// Loads the member profiles once. Best effort like [_syncBusinessInfo]:
  /// offline or an old server just means no suggestions / raw sender ids.
  Future<void> _loadGroupMembers() async {
    try {
      final conversation = await (_db.select(
        _db.conversations,
      )..where((c) => c.id.equals(conversationId))).getSingleOrNull();
      if (conversation?.type != 'group') return;
      final members = await _api.getGroupMemberInfos(conversationId);
      if (_disposed) return;
      _groupMembers = members;
      notifyListeners();
    } catch (_) {}
  }

  /// H2: a business "1:1" is really a business GROUP with exactly one other
  /// non-auditor member plus the auditor — the only shape calls make sense
  /// for (there is no such thing as a group call). Returns that member's
  /// device id, or null when this isn't a business group or has more than
  /// one other member. Not cached: membership can change between opens.
  Future<String?> businessCallTarget() async {
    final info = await _api.getGroupBusinessInfo(conversationId);
    if (!info.isBusiness) return null;
    final members = await _api.getGroupMembers(conversationId);
    final others = members
        .where((id) => id != myIdentityId && id != info.auditorDeviceId)
        .toList();
    return others.length == 1 ? others.single : null;
  }

  final AppDatabase _db;
  final SignalRClient _signalR;
  final SessionManager _sessions;
  final ApiClient _api;
  final String conversationId;
  final DeviceDirectory _directory;
  final BotCommandsCache _commandsCache;

  /// The "/" menu for [bots] of this chat (the 1:1 bot, or the group's bot
  /// members). Lists come from `GET /devices/{id}/bot-commands` through the
  /// 10-minute cache, fetched in parallel; a bot whose list fails just
  /// offers nothing.
  Future<List<CommandSuggestion>> commandSuggestions(
    List<CommandBot> bots, {
    required bool group,
  }) async {
    final lists = await Future.wait([
      for (final bot in bots)
        _commandsCache.get(bot.deviceId, _api.getBotCommands),
    ]);
    return buildCommandSuggestions(
      bots: bots,
      commands: {for (final (i, bot) in bots.indexed) bot.deviceId: lists[i]},
      group: group,
    );
  }

  /// "Me" in this conversation: the IDENTITY id (the primary device id),
  /// which `messages.senderId` stores for every device of this user. Equals
  /// the device id unless this device is a companion; the transport id is
  /// SignalRClient.deviceId.
  String get myIdentityId => _directory.selfIdentityId;

  /// v1: a companion has no calls and no business conversations.
  bool get isCompanion => _directory.isCompanion;

  final FanoutSender _fanout;

  /// Told about every `device_list_stale` answer (the primary reports a
  /// companion the server no longer knows, constraint 5). Must not await
  /// anything that runs in MessageProcessingQueue: it is called from inside it.
  final void Function(Set<String> required)? _onStale;

  static Future<void> _reportIfOwn(
    String deviceId,
    DeviceDirectory directory,
    void Function(String deviceId)? report,
  ) async {
    if (await directory.identityOf(deviceId) == directory.selfIdentityId) {
      report?.call(deviceId);
    }
  }

  /// Rounds of "send; on device_list_stale repair the envelopes and resend".
  /// Bounded: a server that keeps answering stale produces a visible failure,
  /// not a loop.
  static const _maxFanoutRounds = 3;
  late StreamSubscription<List<Message>> _subscription;
  late StreamSubscription<Message> _incoming;
  bool _disposed = false;
  List<Message> _messages = [];
  List<Message> get messages => List.unmodifiable(_messages);
  static const _uuid = Uuid();

  /// Set when the hub rejects a send with `audit_recipient_missing` (Jay
  /// Business mode, KB1) — the archiver was dropped from the fan-out, which
  /// must never happen silently. Cleared on the next send attempt.
  bool _auditRecipientMissing = false;
  bool get auditRecipientMissing => _auditRecipientMissing;

  /// One-shot read: the UI calls this to show its snackbar exactly once per
  /// failure, instead of re-showing it on every rebuild while the flag
  /// stays true.
  bool consumeAuditRecipientMissing() {
    final value = _auditRecipientMissing;
    _auditRecipientMissing = false;
    return value;
  }

  /// Set when the hub rejects a send with `auditor_unavailable` (Jay
  /// Business mode, W2-F fail-closed rule) — the organization's auditor is
  /// not alive right now. Deliberately a SEPARATE flag from
  /// [auditRecipientMissing]: the two causes need distinct wording (one is a
  /// tamper/bug signal, the other an availability problem the user can just
  /// retry). Cleared on the next send attempt.
  bool _auditorUnavailable = false;
  bool get auditorUnavailable => _auditorUnavailable;

  /// One-shot read, same contract as [consumeAuditRecipientMissing].
  bool consumeAuditorUnavailable() {
    final value = _auditorUnavailable;
    _auditorUnavailable = false;
    return value;
  }

  /// Set when the hub/REST rejects a send/group action with
  /// `business_conversation_required` (Jay Business mode, P1 —
  /// `Organization.RequireBusinessConversations`): the recipient is enrolled
  /// in an organization that only allows this pair to talk inside a business
  /// conversation. Deliberately a separate flag — unlike
  /// [auditRecipientMissing]/[auditorUnavailable] this is not a failure to
  /// retry, it's a redirect: the UI offers to open/create the business
  /// conversation instead (see [createBusinessConversationWithPeer]).
  bool _businessConversationRequired = false;
  bool get businessConversationRequired => _businessConversationRequired;

  /// One-shot read, same contract as [consumeAuditRecipientMissing].
  bool consumeBusinessConversationRequired() {
    final value = _businessConversationRequired;
    _businessConversationRequired = false;
    return value;
  }

  /// P1 UI action: finds the organization both the caller and the peer are
  /// actively enrolled in (there is exactly one that could have triggered
  /// `business_conversation_required` for a 1:1 conversation) and creates a
  /// two-member business group with them — the same call the "new business
  /// chat" flow uses. Only meaningful for a 1:1 conversation, where
  /// [conversationId] IS the peer's device id. Returns the new group's id, or
  /// null if no shared organization could be found (should not happen if the
  /// server just rejected the send for this reason, but network state can
  /// have moved on).
  Future<String?> createBusinessConversationWithPeer() async {
    final myOrgs = await _api.getMyOrganizations();
    for (final org in myOrgs) {
      final enrollments = await _api.getOrganizationEnrollments(
        org.organizationId,
      );
      if (enrollments.any((e) => e.deviceId == conversationId)) {
        final response = await _api.createGroup('', [
          conversationId,
        ], organizationId: org.organizationId);
        return response['groupId'] as String;
      }
    }
    return null;
  }

  Future<void> _markRead() async {
    await (_db.update(_db.conversations)
          ..where((c) => c.id.equals(conversationId)))
        .write(const ConversationsCompanion(unreadCount: Value(0)));
  }

  /// Text the composer starts with (bot deep link `/start <payload>`), set
  /// once by the route; never sent without the user pressing send.
  String? initialDraft;

  Message? _replyingTo;

  /// The message the next sent message will quote, or null.
  Message? get replyingTo => _replyingTo;

  void startReply(Message message) {
    _replyingTo = message;
    notifyListeners();
  }

  void cancelReply() {
    if (_replyingTo == null) return;
    _replyingTo = null;
    notifyListeners();
  }

  /// What a quote of [message] shows: the text, or the file name for a file,
  /// cut to [maxReplyPreview]. It is copied into the outgoing payload because
  /// the receiver may not have the original. A media message is quoted by
  /// its caption, else kind + name / duration ([l10n], default English).
  static String replyPreviewOf(Message message, [AppLocalizations? l10n]) {
    var text = message.body ?? '';
    if (message.type == 'file') {
      try {
        text = Attachment.decode(text).name;
      } catch (_) {
        text = '';
      }
    } else if (message.type == 'media') {
      final info = MediaInfo.tryDecode(text);
      text = info == null ? '' : mediaSummary(l10n ?? _english, info);
    }
    return text.length > maxReplyPreview
        ? text.substring(0, maxReplyPreview)
        : text;
  }

  /// Sends a text message. [mentions] are the identity ids of the members
  /// the user picked from the @ suggestions whose `@token` is still in
  /// [text] (MessageInput decides that); they travel as `mentions` so a bot
  /// is addressed even when its handle or name is ambiguous in the text.
  Future<void> sendMessage(String text, {List<String> mentions = const []}) =>
      _send(
        text,
        'text',
        extra: {
          if (mentions.isNotEmpty)
            'mentions': parseMentions(mentions),
        },
      );

  /// A tap on [button] under the bot message [botMessage] (contract section
  /// 1, `action`): a normal text message whose body is the label (an old bot
  /// still understands it), quoting that bot message, plus the machine
  /// readable `action`. Independent of the reply the user may be composing.
  Future<void> sendAction(Message botMessage, MessageButton button) => _send(
    button.label,
    'text',
    reply: botMessage,
    extra: {
      'action': ActionRef(messageId: botMessage.id, id: button.id).toJson(),
    },
  );

  /// Whether [message] may be edited by this user here: an own, sent, plain
  /// text message outside business conversations (same limits as
  /// [deleteForEveryone], see there for why business is excluded).
  bool canEdit(Message message, {required bool business}) =>
      message.senderId == myIdentityId &&
      message.type == 'text' &&
      !message.deleted &&
      !business &&
      message.status != 'sending' &&
      message.status != 'failed';

  /// Replaces the text of an own message for every participant by sending a
  /// `type: edit` control message (contract section 1) with the FULL new
  /// body. Mirrors [deleteForEveryone]: a transient local control row rides
  /// the normal outbox (so our other devices get the edit through the same
  /// fan-out), and the local copy changes only after the send succeeded.
  /// Returns false when not allowed, unchanged, or the send failed.
  Future<bool> editMessage(String messageId, String newText) async {
    final text = newText.trim();
    if (text.isEmpty) return false;
    final target = await (_db.select(
      _db.messages,
    )..where((m) => m.id.equals(messageId))).getSingleOrNull();
    if (target == null ||
        target.conversationId != conversationId ||
        !canEdit(target, business: false) ||
        target.body == text) {
      return false;
    }
    final conversation = await (_db.select(
      _db.conversations,
    )..where((c) => c.id.equals(conversationId))).getSingleOrNull();
    // WHY business is refused (fail closed, exactly like delete): business
    // messages are archived for audit and the archiver does not accept an
    // `edit` (it would stay queued for it until the TTL).
    if (conversation == null || conversation.organizationId != null) {
      return false;
    }
    if (conversation.type == 'group' && !await _confirmNotBusiness()) {
      return false;
    }
    final controlId = _uuid.v4();
    final now = DateTime.now();
    await _db.transaction(() async {
      await _db
          .into(_db.messages)
          .insert(
            MessagesCompanion.insert(
              id: controlId,
              conversationId: conversationId,
              senderId: myIdentityId,
              body: Value(text),
              type: const Value('edit'),
              status: const Value('sending'),
              createdAt: now,
            ),
          );
      await _storeExtra(controlId, {'editOf': messageId});
    });
    await retryMessage(controlId);
    final control = await (_db.select(
      _db.messages,
    )..where((m) => m.id.equals(controlId))).getSingleOrNull();
    final sent = control?.status == 'sent';
    await _db.transaction(() async {
      if (sent) {
        await (_db.update(
          _db.messages,
        )..where((m) => m.id.equals(messageId))).write(
          MessagesCompanion(
            body: Value(text),
            // The same instant the payload carried as createdAt, so this
            // device orders a later copy of its own edit like everybody else.
            editedAt: Value(control!.createdAt),
          ),
        );
      }
      await _dropControl(controlId);
    });
    return sent;
  }

  /// Removes a transient control row with everything that belongs to it.
  Future<void> _dropControl(String controlId) async {
    await (_db.delete(
      _db.messages,
    )..where((m) => m.id.equals(controlId))).go();
    await (_db.delete(_db.backupState)..where(
          (s) => s.key.isIn(['outbox:$controlId', 'extra:$controlId']),
        ))
        .go();
  }

  /// Asks the server whether this group is a business group, failing CLOSED
  /// (a network error counts as "business"). Shared by delete and edit.
  Future<bool> _confirmNotBusiness() async {
    // The cached organizationId may simply not be filled in yet. Asked
    // directly instead of through getGroupBusinessInfo: that helper turns a
    // network error into "not business", which here would mean failing OPEN.
    try {
      final response = await _api.transport.get<Map<String, dynamic>>(
        '/groups/$conversationId',
      );
      return !GroupBusinessInfo.fromJson(response.data!).isBusiness;
    } catch (_) {
      return false;
    }
  }

  /// Payload keys of [messageId] that have no `messages` column (mentions,
  /// a button press, the target of an edit). WHY persisted next to the row
  /// and not kept in memory: a first send can fail BEFORE the outbox (and
  /// with it the exact payload) is written, and the retry may come from
  /// another controller or after a restart. Deleted once the outbox holds
  /// the payload.
  Future<void> _storeExtra(String messageId, Map<String, Object?> extra) async {
    if (extra.isEmpty) return;
    await _db
        .into(_db.backupState)
        .insertOnConflictUpdate(
          BackupStateCompanion.insert(
            key: 'extra:$messageId',
            value: jsonEncode(extra),
          ),
        );
  }

  Future<Map<String, dynamic>> _loadExtra(String messageId) async {
    final row = await (_db.select(
      _db.backupState,
    )..where((s) => s.key.equals('extra:$messageId'))).getSingleOrNull();
    if (row == null) return const {};
    try {
      return jsonDecode(row.value) as Map<String, dynamic>;
    } catch (_) {
      return const {};
    }
  }

  Future<void> sendAttachment(String name, Uint8List bytes) =>
      _send(Attachment(name: name, bytes: bytes).encode(), 'file');

  /// Encrypted media transfers (uploads, downloads, local copies); shared
  /// app-wide so a transfer outlives this chat screen.
  final MediaService media;

  /// The UI language, set by the chat screen: the fallback text old clients
  /// show (contract M7) and media reply quotes are written in the sender's
  /// language. English when unset (tests, background sends).
  AppLocalizations? localizations;

  static final _english = lookupAppLocalizations(const Locale('en'));

  /// Sends [source] through the encrypted media path (contract 4.1): the
  /// file is streamed into local media storage while hashing, an optimistic
  /// row of type `media` appears at once, then the upload runs and finally
  /// the `media` object goes out through the normal encrypted pipeline.
  /// This is also the hook the photo preview screen can call for large
  /// files. Throws [MediaTooLarge] before anything is stored.
  Future<void> sendMedia(
    PickedMedia source, {
    MediaKind? kind,
    String? caption,
    int? durationMs,
    Uint8List? waveform,
    int? width,
    int? height,
    Uint8List? thumbnail,
    String? mime,
  }) async {
    if (!isValidMediaName(source.name)) {
      throw ArgumentError('Invalid media name');
    }
    final id = _uuid.v4();
    final folder = MediaService.uploadFolder(id);
    final stored = await media.importForUpload(
      id,
      source.name,
      source.openRead(),
    );
    final keys = newMediaKey();
    final trimmed = caption?.trim();
    // The receiver drops an invalid `media` object to the fallback text,
    // so whatever a picker reports is normalized here (parameters cut,
    // unknown shapes replaced by the type the name suggests).
    final type = normalizeMediaMime(mime ?? source.mimeType, source.name);
    final info = MediaInfo(
      id: '',
      kind: kind ?? mediaKindFor(source.name, mime: type),
      name: source.name,
      mime: type,
      size: stored.size,
      sha256: stored.sha256,
      key: keys.key,
      nonce: keys.nonce,
      durationMs: durationMs,
      width: width,
      height: height,
      thumbnail: thumbnail != null && thumbnail.length <= 24 * 1024
          ? thumbnail
          : null,
      waveform: waveform == null || waveform.isEmpty ? null : waveform,
      caption: trimmed == null || trimmed.isEmpty
          ? null
          : trimmed.length > 4096
          ? trimmed.substring(0, 4096)
          : trimmed,
    );
    if (MediaInfo.tryParse(info.toJson(), draft: true) == null) {
      await media.deleteLocal(folder);
      throw ArgumentError('Invalid media');
    }
    final now = DateTime.now();
    final reply = _replyingTo;
    if (reply != null) cancelReply();
    await _db.transaction(() async {
      await _db
          .into(_db.messages)
          .insert(
            MessagesCompanion.insert(
              id: id,
              conversationId: conversationId,
              senderId: myIdentityId,
              body: Value(info.encode()),
              type: const Value('media'),
              status: const Value('sending'),
              createdAt: now,
              replyToId: Value(reply?.id),
              replySenderId: Value(reply?.senderId),
              replyPreview: Value(
                reply == null ? null : replyPreviewOf(reply, localizations),
              ),
            ),
          );
      await _storeUploadState(id, folder: folder);
      await (_db.update(_db.conversations)
            ..where((c) => c.id.equals(conversationId)))
          .write(ConversationsCompanion(lastMessageAt: Value(now)));
    });
    await retryMessage(id);
  }

  /// `mediaup:<messageId>`: where the local copy of an unfinished upload
  /// is and whether it finished (contract 4.1). The id, key and nonce live
  /// in the row body (a draft `media` object) and are updated as the
  /// upload proceeds, so a restart resumes through `GET /media/{id}/upload`.
  Future<void> _storeUploadState(
    String messageId, {
    required String folder,
    bool uploaded = false,
  }) => _db
      .into(_db.backupState)
      .insertOnConflictUpdate(
        BackupStateCompanion.insert(
          key: 'mediaup:$messageId',
          value: jsonEncode({'folder': folder, 'uploaded': uploaded}),
        ),
      );

  Future<Map<String, dynamic>?> _loadUploadState(String messageId) async {
    final row = await (_db.select(
      _db.backupState,
    )..where((s) => s.key.equals('mediaup:$messageId'))).getSingleOrNull();
    if (row == null) return null;
    try {
      return jsonDecode(row.value) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Cancel on the bubble: stops the upload, withdraws the blob; the row
  /// becomes `failed` (retry starts a new upload, delete removes it).
  void cancelMediaUpload(String messageId) => media.cancelUpload(messageId);

  /// Runs (or resumes) the upload of an own media row before it can be
  /// sent. Deliberately OUTSIDE MessageProcessingQueue: an upload takes
  /// minutes and must not block decrypting incoming messages. Returns false
  /// when the message must not be sent now.
  Future<bool> _prepareMedia(String messageId) async {
    final message = await (_db.select(
      _db.messages,
    )..where((m) => m.id.equals(messageId))).getSingleOrNull();
    if (message == null || message.type != 'media') return true;
    final state = await _loadUploadState(messageId);
    if (state == null || state['uploaded'] == true) return true;
    if (message.senderId != myIdentityId ||
        message.conversationId != conversationId ||
        (message.status != 'failed' && message.status != 'sending')) {
      return false;
    }
    if (media.isUploading(messageId)) return false;
    final draft = MediaInfo.tryDecode(message.body);
    final folder = state['folder'];
    if (draft == null || folder is! String) {
      await _status(messageId, 'failed');
      return false;
    }
    await _status(messageId, 'sending');
    try {
      final done = await media.upload(
        messageId,
        draft,
        folder: folder,
        persist: (info, folder) => _db.transaction(() async {
          await (_db.update(_db.messages)
                ..where((m) => m.id.equals(messageId)))
              .write(MessagesCompanion(body: Value(info.encode())));
          await _storeUploadState(messageId, folder: folder);
        }),
      );
      await _db.transaction(() async {
        await (_db.update(_db.messages)..where((m) => m.id.equals(messageId)))
            .write(MessagesCompanion(body: Value(done.encode())));
        await _storeUploadState(messageId, folder: done.id, uploaded: true);
      });
      return true;
    } on MediaCancelled {
      await _status(messageId, 'failed');
      return false;
    } catch (_) {
      await _status(messageId, 'failed');
      return false;
    }
  }

  /// Sends [body] into THIS conversation marked as forwarded. The forward UI
  /// navigates to the target chat first and calls this on that chat's own
  /// controller (a second controller would mark the conversation read).
  Future<void> sendForwarded({required String body, required String type}) =>
      _send(body, type, forwarded: true);

  /// Removes the message from this device only. Works for any message,
  /// including tombstones and failed sends (also drops its pending outbox).
  Future<void> deleteForMe(String messageId) async {
    final message = await (_db.select(
      _db.messages,
    )..where((m) => m.id.equals(messageId))).getSingleOrNull();
    await _db.transaction(() async {
      await (_db.delete(
        _db.messages,
      )..where((m) => m.id.equals(messageId))).go();
      await (_db.delete(_db.backupState)..where(
            (s) => s.key.isIn([
              'outbox:$messageId',
              'extra:$messageId',
              'mediaup:$messageId',
            ]),
          ))
          .go();
    });
    if (message?.type == 'media') {
      media.cancelUpload(messageId);
      await deleteUnreferencedMedia(_db, media, message!.body, messageId);
    }
  }

  /// Deletes an own, already sent message for every participant by sending a
  /// `delete` control message through the normal encrypted pipeline. Returns
  /// false (and leaves the original untouched) if it is not allowed or the
  /// send failed, so the UI can say so.
  Future<bool> deleteForEveryone(String messageId) async {
    final target = await (_db.select(
      _db.messages,
    )..where((m) => m.id.equals(messageId))).getSingleOrNull();
    if (target == null ||
        target.senderId != myIdentityId ||
        target.conversationId != conversationId ||
        target.deleted ||
        target.type == 'call-event' ||
        target.type == 'delete' ||
        target.status == 'sending' ||
        target.status == 'failed') {
      return false;
    }
    final conversation = await (_db.select(
      _db.conversations,
    )..where((c) => c.id.equals(conversationId))).getSingleOrNull();
    if (conversation == null || conversation.organizationId != null) {
      return false;
    }
    // Fail CLOSED: business messages are archived and must never be
    // retracted.
    if (conversation.type == 'group' && !await _confirmNotBusiness()) {
      return false;
    }
    // A local row of type 'delete' reuses the outbox, so a retry resends the
    // SAME ciphertext and the receiver's redelivery marker keeps it idempotent.
    // It deliberately does not touch lastMessageAt.
    final controlId = _uuid.v4();
    await _db
        .into(_db.messages)
        .insert(
          MessagesCompanion.insert(
            id: controlId,
            conversationId: conversationId,
            senderId: myIdentityId,
            body: Value(messageId),
            type: const Value('delete'),
            status: const Value('sending'),
            createdAt: DateTime.now(),
          ),
        );
    await retryMessage(controlId);
    final control = await (_db.select(
      _db.messages,
    )..where((m) => m.id.equals(controlId))).getSingleOrNull();
    final sent = control?.status == 'sent';
    await _db.transaction(() async {
      // Only after a successful send does the original change, exactly like
      // on the receiving side.
      if (sent) await tombstoneMessage(_db, messageId);
      await (_db.delete(
        _db.messages,
      )..where((m) => m.id.equals(controlId))).go();
      await (_db.delete(
        _db.backupState,
      )..where((s) => s.key.equals('outbox:$controlId'))).go();
    });
    if (sent && target.type == 'media') {
      await deleteUnreferencedMedia(_db, media, target.body, messageId);
    }
    return sent;
  }

  Future<void> _send(
    String text,
    String type, {
    bool forwarded = false,
    Message? reply,
    Map<String, Object?> extra = const {},
  }) async {
    if (text.trim().isEmpty) return;
    final id = _uuid.v4();
    final now = DateTime.now();
    if (reply == null) {
      reply = forwarded ? null : _replyingTo;
      if (reply != null) cancelReply();
    }
    await _db.transaction(() async {
      await _storeExtra(id, extra);
      await _db
          .into(_db.messages)
          .insert(
            MessagesCompanion.insert(
              id: id,
              conversationId: conversationId,
              senderId: myIdentityId,
              body: Value(text),
              type: Value(type),
              status: const Value('sending'),
              createdAt: now,
              replyToId: Value(reply?.id),
              replySenderId: Value(reply?.senderId),
              replyPreview: Value(
                reply == null ? null : replyPreviewOf(reply, localizations),
              ),
              forwarded: Value(forwarded),
            ),
          );
      await (_db.update(_db.conversations)
            ..where((c) => c.id.equals(conversationId)))
          .write(ConversationsCompanion(lastMessageAt: Value(now)));
    });
    await retryMessage(id);
  }

  /// Sends (again) an own message. A media row first finishes its upload,
  /// outside the processing queue (see [_prepareMedia]).
  Future<void> retryMessage(String messageId) async {
    if (!await _prepareMedia(messageId)) return;
    await _sendQueued(messageId);
  }

  Future<void> _sendQueued(
    String messageId,
  ) => MessageProcessingQueue.forDatabase(_db).run(() async {
    final message = await (_db.select(
      _db.messages,
    )..where((m) => m.id.equals(messageId))).getSingle();
    if (message.senderId != myIdentityId ||
        message.conversationId != conversationId ||
        (message.status != 'failed' && message.status != 'sending')) {
      return;
    }
    await _status(messageId, 'sending');
    _auditRecipientMissing = false;
    _auditorUnavailable = false;
    _businessConversationRequired = false;
    try {
      var stored = await (_db.select(
        _db.backupState,
      )..where((s) => s.key.equals('outbox:$messageId'))).getSingleOrNull();
      if (stored == null) {
        final conversation = await (_db.select(
          _db.conversations,
        )..where((c) => c.id.equals(conversationId))).getSingle();
        final groupId = conversation.type == 'group' ? conversationId : null;
        // Business conversations stay on the per-member group call from the
        // primary: KB2 auditor rules are defined over member devices and the
        // hub refuses fan-out there. v1 keeps companions out of them.
        final business = conversation.organizationId != null;
        if (business && isCompanion) {
          throw StateError('Business conversations are primary-only in v1.');
        }
        final recipients = groupId == null
            ? [conversationId]
            : (await _api.getGroupMembers(
                groupId,
              )).where((id) => id != myIdentityId).toList();
        if (recipients.isEmpty) {
          throw StateError('No recipients in this conversation');
        }
        // Contract M7: media goes out as `text` with a fallback body for old
        // clients plus the `media` object new clients read.
        final mediaInfo = message.type == 'media'
            ? MediaInfo.tryDecode(message.body)
            : null;
        if (message.type == 'media' &&
            (mediaInfo == null || mediaInfo.isDraft)) {
          throw StateError('Media message is not uploaded');
        }
        final payload = jsonEncode({
          'v': 1,
          'id': messageId,
          'body': mediaInfo == null
              ? message.body
              : mediaFallbackBody(localizations ?? _english, mediaInfo),
          'type': mediaInfo == null ? message.type : 'text',
          if (mediaInfo != null) 'media': mediaInfo.toJson(),
          'groupId': groupId,
          'groupName': groupId == null ? null : conversation.title,
          'createdAt': message.createdAt.toUtc().toIso8601String(),
          // Multi-device: our OTHER devices get a copy too, and only this
          // says which direct conversation it belongs to (constraint 4).
          if (groupId == null) 'to': conversationId,
          // Additive keys: old clients ignore them and show a normal message.
          if (message.replyToId != null)
            'replyTo': {
              'id': message.replyToId,
              'senderId': message.replySenderId,
              'preview': message.replyPreview ?? '',
            },
          if (message.forwarded) 'forwarded': true,
          // mentions / action / editOf (agent messaging contract section 1).
          ...await _loadExtra(messageId),
        });
        await _db.transaction(() async {
          final Map<String, String> envelopes;
          if (business) {
            final encrypted = await GroupCipher(
              sessionManager: _sessions,
              ensureSession: _ensureSession,
            ).encryptForGroup(groupId!, recipients, payload);
            envelopes = encrypted.map(
              (id, bytes) => MapEntry(id, base64Encode(bytes)),
            );
          } else {
            // One envelope per VERIFIED device of the recipients and of our
            // own identity, from stored lists only (no fetch per message).
            envelopes = await _fanout.encrypt(recipients, payload);
          }
          await _db
              .into(_db.backupState)
              .insert(
                BackupStateCompanion.insert(
                  key: 'outbox:$messageId',
                  // Recipients and the exact payload are kept for a stale
                  // answer: a missing device gets a new envelope while every
                  // existing one is resent byte for byte.
                  value: jsonEncode({
                    'groupId': groupId,
                    'envelopes': envelopes,
                    if (!business)
                      'fanout': {'identityIds': recipients, 'payload': payload},
                  }),
                ),
              );
          // The payload above now carries the extra keys for every retry.
          await (_db.delete(
            _db.backupState,
          )..where((s) => s.key.equals('extra:$messageId'))).go();
        });
        stored = await (_db.select(
          _db.backupState,
        )..where((s) => s.key.equals('outbox:$messageId'))).getSingle();
      }
      final outbox = jsonDecode(stored.value) as Map<String, dynamic>;
      final envelopes = (outbox['envelopes'] as Map<String, dynamic>)
          .cast<String, String>();
      final groupId = outbox['groupId'] as String?;
      if (outbox['fanout'] != null) {
        await _sendFanout(messageId, outbox, envelopes);
      } else if (groupId != null) {
        // The whole fan-out in one call (see sendGroupMessage): a business
        // group rejects any call without the auditor's envelope (KB2).
        await _signalR.sendGroupMessage(
          groupId,
          envelopes,
          messageId: messageId,
        );
      } else {
        // An outbox written before multi-device (one envelope for the peer):
        // finish it the old way rather than encrypting again.
        await _signalR.sendMessage(
          envelopes.keys.single,
          envelopes.values.single,
          messageId: messageId,
        );
      }
      await _db.transaction(() async {
        await _status(messageId, 'sent');
        await (_db.delete(_db.backupState)..where(
              (s) => s.key.isIn(['outbox:$messageId', 'mediaup:$messageId']),
            ))
            .go();
      });
    } catch (e) {
      // The hub reports the audit failure as a plain-text HubException
      // message; surfacing it distinctly (rather than a generic "failed")
      // is required by KB1 — this must never look like an ordinary
      // delivery hiccup the user can ignore.
      if (e.toString().contains('audit_recipient_missing')) {
        _auditRecipientMissing = true;
        notifyListeners();
      } else if (e.toString().contains('auditor_unavailable')) {
        _auditorUnavailable = true;
        notifyListeners();
      } else if (e.toString().contains('business_conversation_required')) {
        _businessConversationRequired = true;
        notifyListeners();
      }
      await _status(messageId, 'failed');
    }
  });

  /// Sends a fan-out outbox; on `device_list_stale` lets FanoutSender repair
  /// the envelopes (new devices get one, removed devices lose theirs, the
  /// rest stays byte for byte) and persists them before the next round.
  Future<void> _sendFanout(
    String messageId,
    Map<String, dynamic> outbox,
    Map<String, String> envelopes,
  ) async {
    final groupId = outbox['groupId'] as String?;
    final fanout = outbox['fanout'] as Map<String, dynamic>;
    var identityIds = (fanout['identityIds'] as List).cast<String>();
    final payload = fanout['payload'] as String;
    var current = envelopes;
    for (var round = 1; ; round++) {
      try {
        if (groupId == null) {
          await _signalR.sendDirectFanout(
            identityIds.single,
            current,
            messageId: messageId,
          );
        } else {
          await _signalR.sendGroupFanout(
            groupId,
            current,
            messageId: messageId,
          );
        }
        return;
      } catch (e) {
        if (groupId != null &&
            e.toString().contains('fanout_unsupported_in_business_group')) {
          await _sendBusinessFallback(messageId, groupId, payload);
          return;
        }
        final required = core.SignalRClient.staleRequired(e);
        if (required == null || round == _maxFanoutRounds) rethrow;
        _onStale?.call(required);
        if (groupId != null) {
          // The hub computes `required` from the CURRENT membership, but the
          // stored identityIds are from the first attempt. Without this a
          // member added before a retry stays "unverified" for good and every
          // retry fails. The union keeps removed members out of nothing:
          // reconcile already trims envelopes the hub no longer wants. Same
          // trust as the first send (the member list comes from the server).
          final members = await _api.getGroupMembers(groupId);
          identityIds = {
            ...identityIds,
            ...members.where((id) => id != myIdentityId),
          }.toList();
        }
        // Deliberately NOT inside a database transaction: reconcile refreshes
        // device lists, DeviceDirectory serializes its refreshes, and a
        // transaction held across that could wait for a refresh that waits
        // for the database. A crash in between only loses envelopes nobody
        // has received; encrypting those again is harmless.
        current = await _fanout.reconcile(
          envelopes: current,
          required: required,
          identityIds: identityIds,
          payload: payload,
        );
        await (_db.update(_db.backupState)
              ..where((s) => s.key.equals('outbox:$messageId')))
            .write(
              BackupStateCompanion(
                value: Value(
                  jsonEncode({
                    ...outbox,
                    'envelopes': current,
                    'fanout': {...fanout, 'identityIds': identityIds},
                  }),
                ),
              ),
            );
      }
    }
  }

  /// The hub says this group is a business group, but the local cache did
  /// not know yet (it is filled asynchronously when the chat opens). Finish
  /// the SAME send attempt on the business path instead of failing: same
  /// messageId, one envelope per member from the server's member list (the
  /// auditor included, KB2), one sendGroupMessage call. The refused fan-out
  /// call queued nothing, so encrypting again only skips a ratchet step.
  Future<void> _sendBusinessFallback(
    String messageId,
    String groupId,
    String payload,
  ) async {
    // v1: business conversations are primary-only (decision 2).
    if (isCompanion) {
      throw StateError('Business conversations are primary-only in v1.');
    }
    // Fills the cached organizationId, so the next send goes straight to the
    // business path (and the banner appears).
    await _syncBusinessInfo();
    final recipients = (await _api.getGroupMembers(
      groupId,
    )).where((id) => id != myIdentityId).toList();
    final envelopes = <String, String>{};
    await _db.transaction(() async {
      final encrypted = await GroupCipher(
        sessionManager: _sessions,
        ensureSession: _ensureSession,
      ).encryptForGroup(groupId, recipients, payload);
      envelopes.addAll(
        encrypted.map((id, bytes) => MapEntry(id, base64Encode(bytes))),
      );
      // The outbox becomes a business outbox: a retry after a failed call
      // below resends these exact envelopes through the business branch.
      await (_db.update(_db.backupState)
            ..where((s) => s.key.equals('outbox:$messageId')))
          .write(
            BackupStateCompanion(
              value: Value(
                jsonEncode({'groupId': groupId, 'envelopes': envelopes}),
              ),
            ),
          );
    });
    await _signalR.sendGroupMessage(groupId, envelopes, messageId: messageId);
  }

  Future<void> _status(String id, String status) =>
      (_db.update(_db.messages)..where((m) => m.id.equals(id)))
          .write(MessagesCompanion(status: Value(status)))
          .then((_) {});

  Future<void> _ensureSession(String recipient) async {
    if (!await _sessions.hasSession(recipient)) {
      await _sessions.initiateSession(
        recipient,
        await _api.getKeyBundle(recipient),
      );
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _subscription.cancel();
    _incoming.cancel();
    super.dispose();
  }
}
