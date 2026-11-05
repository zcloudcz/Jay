import 'dart:async';
import 'dart:convert';

import 'package:calltype_core/crypto/device_list.dart' show DeviceListException;
import 'package:calltype_core/devices/device_directory.dart';
import 'package:calltype_core/messaging/agent_payload.dart';
import 'package:drift/drift.dart';

import '../../core/crypto/session_manager.dart';
import '../../core/network/api_client.dart';
import '../../core/storage/database.dart';
import 'attachment.dart';

/// One queue per device database protects ratchet updates across chats and inbox.
class MessageProcessingQueue {
  static final _queues = Expando<MessageProcessingQueue>();
  static MessageProcessingQueue forDatabase(AppDatabase db) =>
      _queues[db] ??= MessageProcessingQueue();
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

/// Longest quote kept in a `replyTo` preview.
const maxReplyPreview = 140;

/// Turns a stored message into its "deleted for everyone" tombstone. Shared by
/// the receiver (a `delete` control message) and the sender (after the control
/// message was sent) so both sides end in exactly the same state.
Future<void> tombstoneMessage(AppDatabase db, String messageId) =>
    (db.update(db.messages)..where((m) => m.id.equals(messageId))).write(
      const MessagesCompanion(
        body: Value(null),
        type: Value('text'),
        attachmentPath: Value(null),
        // A deleted bot message must not keep pressable buttons.
        actionsJson: Value(null),
        replyToId: Value(null),
        replySenderId: Value(null),
        replyPreview: Value(null),
        forwarded: Value(false),
        deleted: Value(true),
      ),
    );

/// Persists incoming messages before acknowledging their server queue entries.
///
/// Multi-device: the hub's `senderId` is the sending DEVICE. [directory]
/// turns it into the identity that `messages.senderId` stores and decides
/// the conversation: a contact's companion lands in the contact's
/// conversation, a copy from one of our own devices in the one named by `to`.
class MessageInboxService {
  MessageInboxService({
    required AppDatabase database,
    required SessionManager sessionManager,
    required Stream<Map<String, dynamic>> incomingMessages,
    required DeviceDirectory Function() directory,
    ApiClient? apiClient,
    Future<void> Function(String senderId, String messageId)? acknowledge,
  }) : _db = database,
       _sessionManager = sessionManager,
       _incoming = incomingMessages,
       _directory = directory,
       _api = apiClient,
       _acknowledge = acknowledge;

  final AppDatabase _db;
  final SessionManager _sessionManager;
  final Stream<Map<String, dynamic>> _incoming;

  /// A getter, not the directory itself: the app builds the inbox at startup,
  /// before onboarding has given a fresh install its id (DeviceService.open).
  final DeviceDirectory Function() _directory;

  /// Fetches the key bundle of a sender's PRIMARY when its list must be
  /// verified (the primary's pin is the trust anchor).
  final ApiClient? _api;

  final Future<void> Function(String, String)? _acknowledge;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  final _persisted = StreamController<Message>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  Stream<Message> get persistedMessages => _persisted.stream;
  Stream<Object> get errors => _errors.stream;
  Future<void> _pending = Future.value();

  void start() {
    _subscription ??= _incoming.listen((data) {
      _pending = MessageProcessingQueue.forDatabase(
        _db,
      ).run(() => _handleIncoming(data));
    });
  }

  Future<void> _handleIncoming(Map<String, dynamic> data) async {
    try {
      final senderId = data['senderId'] as String?;
      final messageId = data['messageId'] as String?;
      final groupId = data['groupId'] as String?;
      if (senderId == null ||
          senderId.isEmpty ||
          messageId == null ||
          messageId.isEmpty) {
        throw const FormatException('Missing message identity');
      }
      final directory = _directory();
      // A `delete` control message never gets a messages row, so redelivery
      // (ack lost) is recognised by this marker instead of the row below.
      // Replaying it would otherwise fail in the ratchet and stay queued.
      final handled = await (_db.select(
        _db.backupState,
      )..where((s) => s.key.equals('control:$messageId'))).getSingleOrNull();
      if (handled != null) {
        await _acknowledge?.call(senderId, messageId);
        return;
      }
      final existing = await (_db.select(
        _db.messages,
      )..where((m) => m.id.equals(messageId))).getSingleOrNull();
      if (existing != null) {
        // Rows store the sender's IDENTITY (a companion's message is filed
        // under its primary), but attribution can change between delivery and
        // redelivery (the companion was removed from the list, or the row was
        // filed while the sender was still standalone). Acking is a pure
        // queue operation here, nothing is written, so a changed attribution
        // must not leave the entry stuck on the server forever. Only a
        // redelivery that claims another GROUP stays a conflict.
        if (groupId != null && existing.conversationId != groupId) {
          throw const FormatException('Conflicting message identity');
        }
        await _acknowledge?.call(senderId, messageId);
        return;
      }
      // Constraint 1: a device we never talked to may be a companion of
      // somebody we know. Look it up once, before decrypting, and only then:
      // a known sender has a session, so this costs nothing per message. No
      // contact row is created here (that would mark the device as claimed).
      if (await directory.identityOf(senderId) == senderId.toLowerCase() &&
          !await _sessionManager.hasSession(senderId)) {
        try {
          await directory.refresh(senderId, ensurePinned: _ensureSession);
        } on DeviceListException {
          // The server served a list that does not verify: the sender stays
          // a standalone device, exactly as before multi-device. Attribution
          // is never forced.
        }
        // Any other error (network, 429, 5xx) is transient and propagates
        // BEFORE decrypting: nothing is decrypted, no session or ratchet step
        // exists and nothing is acked, so the message stays queued on the
        // server and is retried on reconnect. Swallowing it would file a
        // companion's messages as a stranger's forever, because later
        // messages already have a session and never refresh again.
      }
      // The server's attribution of the sender is only a HINT. If it names
      // another identity than our verified list does, our list may be stale
      // (an owner removed this companion, maybe a stolen browser): re-read it
      // so the device stops being shown as the owner as soon as it writes.
      // Attribution itself still comes only from the verified list. Same error
      // rule as above: an unverifiable list keeps the local view, anything
      // else rethrows before decrypting so the message stays queued.
      final hint = (data['senderPrimaryId'] as String?)?.toLowerCase();
      if (hint != null &&
          hint.isNotEmpty &&
          hint != await directory.identityOf(senderId)) {
        try {
          await directory.refresh(senderId, ensurePinned: _ensureSession);
        } on DeviceListException {
          // Keep the local view.
        }
      }
      // Membership was authorized by the relay when it accepted the message.
      // Current membership can differ after an offline recipient reconnects.
      Message? inserted;
      await _db.transaction(() async {
        final envelope = utf8.decode(
          base64Decode(data['encryptedBody'] as String),
        );
        final plaintext = await _sessionManager.decryptMessage(
          senderId,
          envelope,
          deferPreKeyCleanup: true,
        );
        // Constraint 2: the keys this device used (pinned by the decrypt
        // above) must be the keys its primary signed into the list. On a
        // mismatch the message is DROPPED: the ratchet step commits with this
        // transaction, so it is not decrypted again, and the caller
        // acknowledges it, but it is never stored or shown.
        try {
          await directory.assertListedKeys(senderId);
        } on DeviceListException {
          return;
        }
        final payload = jsonDecode(plaintext) as Map<String, dynamic>;
        if (payload['v'] != 1 ||
            payload['id'] != messageId ||
            payload['groupId'] != groupId ||
            payload['body'] is! String) {
          throw const FormatException(
            'Encrypted message context does not match delivery',
          );
        }
        final type = payload['type'] as String? ?? 'text';
        // 'delete' and 'edit' are control messages added after the first
        // release. An OLD client throws here, so the message stays queued on
        // the server for it (accepted: that client keeps showing the original
        // message).
        if (type != 'text' &&
            type != 'file' &&
            type != 'call-event' &&
            type != 'delete' &&
            type != 'edit') {
          throw const FormatException('Unsupported message type');
        }
        // Who sent it and where it belongs. `to` is honoured only for copies
        // from our own devices (DeviceDirectory.routeInbound): a peer cannot
        // steer a message into another conversation with it.
        final to = payload['to'];
        final InboundRoute route;
        try {
          route = await directory.routeInbound(
            senderDeviceId: senderId,
            groupId: groupId,
            to: to is String ? to : null,
          );
        } on DeviceListException {
          // An own copy without `to` is a bug of our own other device, not an
          // attack, and retrying cannot fix it. Drop it and let the caller
          // ack it instead of re-decrypting it until the server's TTL.
          return;
        }
        final conversationId = route.conversationId;
        if (type == 'delete') {
          await _applyDelete(
            targetId: payload['body'] as String,
            senderId: route.senderIdentityId,
            conversationId: conversationId,
          );
          await _db
              .into(_db.backupState)
              .insert(
                BackupStateCompanion.insert(
                  key: 'control:$messageId',
                  value: '1',
                ),
              );
          return;
        }
        if (type == 'edit') {
          // Contract section 1: an edit never creates a row and never touches
          // unreadCount; legitimate or not it is acked and remembered by the
          // same `control:` marker as a delete, so a redelivery is a no-op.
          await _applyEdit(
            payload: payload,
            senderId: route.senderIdentityId,
            conversationId: conversationId,
          );
          await _db
              .into(_db.backupState)
              .insert(
                BackupStateCompanion.insert(
                  key: 'control:$messageId',
                  value: '1',
                ),
              );
          return;
        }
        if (type == 'file') Attachment.decode(payload['body'] as String);
        final now = DateTime.now();
        final createdAt =
            DateTime.tryParse(payload['createdAt'] as String? ?? '') ?? now;
        final conversation = await (_db.select(
          _db.conversations,
        )..where((c) => c.id.equals(conversationId))).getSingleOrNull();
        if (conversation == null) {
          await _db
              .into(_db.conversations)
              .insert(
                ConversationsCompanion.insert(
                  id: conversationId,
                  type: groupId == null ? 'direct' : 'group',
                  title: Value(
                    groupId == null ? null : payload['groupName'] as String?,
                  ),
                ),
              );
        } else if (conversation.type !=
            (groupId == null ? 'direct' : 'group')) {
          throw const FormatException('Conflicting conversation type');
        }
        // WHY defensive: replyTo is attacker-controlled JSON; a malformed one
        // must drop the quote, never the message. The preview is the SENDER's
        // claim about what was quoted (same limit as WhatsApp): we cannot
        // verify it against the original, which we may not even have.
        final replyTo = payload['replyTo'];
        String? replyToId, replySenderId, replyPreview;
        if (replyTo is Map &&
            replyTo['id'] is String &&
            replyTo['senderId'] is String &&
            replyTo['preview'] is String) {
          replyToId = replyTo['id'] as String;
          replySenderId = replyTo['senderId'] as String;
          final preview = replyTo['preview'] as String;
          replyPreview = preview.length > maxReplyPreview
              ? preview.substring(0, maxReplyPreview)
              : preview;
        }
        await _db
            .into(_db.messages)
            .insert(
              MessagesCompanion.insert(
                id: messageId,
                conversationId: conversationId,
                senderId: route.senderIdentityId,
                body: Value(payload['body'] as String),
                type: Value(type),
                // A copy of what our other device sent is OUR message: shown
                // as sent, like on the device that wrote it.
                status: Value(route.own ? 'sent' : 'delivered'),
                createdAt: createdAt,
                receivedAt: Value(route.own ? null : now),
                replyToId: Value(replyToId),
                replySenderId: Value(replySenderId),
                replyPreview: Value(replyPreview),
                forwarded: Value(payload['forwarded'] == true),
                // Stored for every sender; the chat renders them only under
                // a BOT's message (a human's buttons could phish). Invalid
                // entries are dropped by parseActions, never the message.
                actionsJson: Value(
                  type == 'text'
                      ? encodeActionsJson(parseActions(payload['actions']))
                      : null,
                ),
              ),
            );
        await (_db.update(
          _db.conversations,
        )..where((c) => c.id.equals(conversationId))).write(
          ConversationsCompanion(
            lastMessageAt: Value(now),
            // A call-event is a log line and an own copy was written by us:
            // neither is something to "read" (H2).
            unreadCount: Value(
              (conversation?.unreadCount ?? 0) +
                  (route.own || type == 'call-event' ? 0 : 1),
            ),
          ),
        );
        inserted = await (_db.select(
          _db.messages,
        )..where((m) => m.id.equals(messageId))).getSingle();
      });
      await _sessionManager.finalizePreKeyCleanup();
      if (inserted != null) _persisted.add(inserted!);
      await _acknowledge?.call(senderId, messageId);
    } catch (error) {
      // Leave failures queued on the server; never report corrupt ciphertext as delivered.
      _errors.add(error);
    }
  }

  Future<void> _ensureSession(String deviceId) async {
    final api = _api;
    if (api == null) throw StateError('No API client to fetch a key bundle.');
    if (!await _sessionManager.hasSession(deviceId)) {
      await _sessionManager.initiateSession(
        deviceId,
        await api.getKeyBundle(deviceId),
      );
    }
  }

  /// Tombstones [targetId] if, and only if, the delete is legitimate.
  /// Illegitimate deletes are silently ignored (the caller still acks them so
  /// they leave the server queue).
  Future<void> _applyDelete({
    required String targetId,
    required String senderId,
    required String conversationId,
  }) async {
    final target = await (_db.select(
      _db.messages,
    )..where((m) => m.id.equals(targetId))).getSingleOrNull();
    if (target == null) return;
    // SECURITY: the relay authenticates only the sender of THIS control
    // message, so we must check the target is that sender's own message in
    // that same conversation. Without it any contact could erase anybody's
    // messages by guessing or learning an id.
    if (target.conversationId != conversationId ||
        target.senderId != senderId) {
      return;
    }
    final conversation = await (_db.select(
      _db.conversations,
    )..where((c) => c.id.equals(conversationId))).getSingleOrNull();
    // Business conversations are archived for audit; they never support
    // deleting for everyone (the client does not send it either).
    if (conversation == null || conversation.organizationId != null) return;
    await tombstoneMessage(_db, targetId);
  }

  /// Applies a `type: edit` (contract section 1) if, and only if, it is
  /// legitimate; anything else is dropped silently (the caller still acks).
  Future<void> _applyEdit({
    required Map<String, dynamic> payload,
    required String senderId,
    required String conversationId,
  }) async {
    final targetId = parseEditOf(payload['editOf']);
    if (targetId == null) return;
    final target = await (_db.select(
      _db.messages,
    )..where((m) => m.id.equals(targetId))).getSingleOrNull();
    if (target == null) return;
    // SECURITY: same reasoning as _applyDelete. The relay authenticates only
    // the sender of THIS message, so the target must be that sender's own
    // message in this very conversation. Only plain text is editable: a file
    // body is an encoded attachment and a tombstone stays deleted.
    if (target.conversationId != conversationId ||
        target.senderId != senderId ||
        target.type != 'text' ||
        target.deleted) {
      return;
    }
    // A missing / unparsable createdAt falls back to "now", like a normal
    // message does; it still loses against a later, correctly dated edit.
    final editedAt =
        DateTime.tryParse(payload['createdAt'] as String? ?? '') ??
        DateTime.now();
    // Out-of-order delivery: progress edits of a bot arrive in any order,
    // the newest one must win. WHY compared at whole seconds and ties
    // applied: drift stores DateTime with second precision, and a bot's final
    // answer can follow its last progress edit within the same second. Both
    // come from one sender over one ordered ratchet, so within a second the
    // arrival order is the sending order; a true duplicate never gets here
    // (the `control:` marker acks it before decrypting).
    final previous = target.editedAt;
    final seconds = DateTime.fromMillisecondsSinceEpoch(
      editedAt.millisecondsSinceEpoch ~/ 1000 * 1000,
      isUtc: true,
    );
    if (previous != null && seconds.isBefore(previous)) return;
    await (_db.update(_db.messages)..where((m) => m.id.equals(targetId))).write(
      MessagesCompanion(
        body: Value(payload['body'] as String),
        editedAt: Value(editedAt),
        // Key present = replace the buttons (an empty list removes them,
        // e.g. after an approval was answered); key absent = keep them.
        actionsJson: payload.containsKey('actions')
            ? Value(encodeActionsJson(parseActions(payload['actions'])))
            : const Value.absent(),
      ),
    );
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    await _pending;
    await _persisted.close();
    await _errors.close();
  }
}
