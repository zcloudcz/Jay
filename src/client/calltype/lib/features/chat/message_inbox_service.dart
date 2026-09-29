import 'dart:async';
import 'dart:convert';

import 'package:calltype_core/devices/device_directory.dart';
import 'package:calltype_core/storage/block_list.dart';
import 'package:drift/drift.dart';

import '../../core/crypto/session_manager.dart';
import '../../core/network/api_client.dart';
import '../../core/storage/database.dart';
import 'inbound/inbound_dispatcher.dart';
import 'inbound/inbound_handler.dart';

export 'inbound/inbound_handler.dart';

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

/// Decrypts and processes EVERY incoming message, and acknowledges it to
/// the server only after the result is durably committed.
///
/// Processing one message (contracts §3, K1, K3):
/// 1. Dedup BEFORE decrypting: an id already in `InboundLog` (or, for rows
///    from before schema v4, in `Messages`) is only re-acknowledged — its
///    ratchet key is spent, decrypting again would fail forever.
/// 2. In ONE transaction: decrypt, validate the envelope against the
///    delivery, drop blocked senders, dispatch to the handler registered for
///    the payload `type` ([registerHandler]), record the id in `InboundLog`.
/// 3. After the commit: emit (content → [persistedMessages], control →
///    [controlEvents]) and ACK.
///
/// Decryption failures and envelope mismatches are NOT acknowledged (the
/// server keeps the message; never report corrupt ciphertext as delivered).
/// A handler's [FormatException] (well-decrypted but malformed) IS
/// acknowledged and dropped, see [InboundTypeHandler].
class MessageInboxService {
  MessageInboxService({
    required AppDatabase database,
    required SessionManager sessionManager,
    required Stream<Map<String, dynamic>> incomingMessages,
    ApiClient? apiClient,
    Future<void> Function(String senderId, String messageId)? acknowledge,
    DeviceDirectory? directory,
    String Function()? myDeviceId,
    DateTime Function() clock = DateTime.now,
  }) : _db = database,
       _sessionManager = sessionManager,
       _incoming = incomingMessages,
       _acknowledge = acknowledge,
       _myDeviceId = myDeviceId ?? (() => ''),
       _clock = clock {
    // Wave 1 default: a contact is one device. main.dart passes the shared
    // DeviceDirectory once it is provided (stream D swaps it in wave 2).
    _directory =
        directory ??
        SingleDeviceDirectory(database: database, myDeviceId: _myDeviceId);
  }

  final AppDatabase _db;
  final SessionManager _sessionManager;
  final Stream<Map<String, dynamic>> _incoming;
  late final DeviceDirectory _directory;
  final String Function() _myDeviceId;
  final DateTime Function() _clock;
  final _dispatcher = InboundDispatcher();

  final Future<void> Function(String, String)? _acknowledge;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  final _persisted = StreamController<Message>.broadcast();
  final _controlEvents = StreamController<ControlEvent>.broadcast();
  final _errors = StreamController<Object>.broadcast();

  /// ONLY content rows (text, file, call-event, media, unknown content) —
  /// never control messages. Stream N notifies from this.
  Stream<Message> get persistedMessages => _persisted.stream;

  /// Applied control messages (receipt, reaction, edit, delete, …).
  Stream<ControlEvent> get controlEvents => _controlEvents.stream;
  Stream<Object> get errors => _errors.stream;
  Future<void> _pending = Future.value();

  /// Hook for stream G (`PeerDirectory.isBlocked`). True → the message is
  /// decrypted (keeping the ratchet in step), recorded, acknowledged and
  /// dropped. Runs inside the transaction: must not call the network.
  /// Default: the `BlockedDevices` table, the single source of truth (K8).
  late FutureOr<bool> Function(String senderId) isBlocked = (senderId) =>
      isDeviceBlocked(_db, senderId);

  /// Registers the handler for a wire `type`, before [start].
  void registerHandler(String type, InboundTypeHandler handler) =>
      _dispatcher.register(type, handler);

  /// See [InboundDispatcher.addPayloadObserver].
  void addPayloadObserver(InboundPayloadObserver observer) =>
      _dispatcher.addPayloadObserver(observer);

  /// Re-entrant dispatch for handlers that unpack nested content (D `sync`).
  /// Only valid while the caller's handler is running.
  Future<InboundResult> dispatch(InboundContext ctx) =>
      _dispatcher.dispatch(ctx);

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
      final conversationId =
          groupId ?? await _directory.directConversationFor(senderId);
      if (await _alreadyProcessed(senderId, messageId, conversationId)) {
        await _acknowledge?.call(senderId, messageId);
        return;
      }
      // Membership was authorized by the relay when it accepted the message.
      // Current membership can differ after an offline recipient reconnects.
      late InboundResult result;
      await _db.transaction(() async {
        final envelope = utf8.decode(
          base64Decode(data['encryptedBody'] as String),
        );
        final plaintext = await _sessionManager.decryptMessage(
          senderId,
          envelope,
          deferPreKeyCleanup: true,
        );
        final payload = jsonDecode(plaintext) as Map<String, dynamic>;
        // Bind the encrypted content to the (server-controlled) delivery,
        // otherwise the server could replay a 1:1 message into a group or
        // under another id.
        if (payload['v'] != 1 ||
            payload['id'] != messageId ||
            payload['groupId'] != groupId ||
            payload['body'] is! String) {
          throw const FormatException(
            'Encrypted message context does not match delivery',
          );
        }
        final now = _clock();
        result = await _process(
          InboundContext(
            db: _db,
            messageId: messageId,
            senderId: senderId,
            conversationId: conversationId,
            myDeviceId: _myDeviceId(),
            groupId: groupId,
            payload: payload,
            serverCreatedAt:
                DateTime.tryParse(data['createdAt'] as String? ?? '') ?? now,
            now: now,
          ),
        );
        // EVERY processed id — content, control, unknown, dropped — so a
        // redelivery after a lost ACK is recognised before decryption.
        await _db
            .into(_db.inboundLog)
            .insertOnConflictUpdate(
              InboundLogCompanion.insert(
                senderId: senderId,
                messageId: messageId,
                processedAt: now,
              ),
            );
      });
      await _sessionManager.finalizePreKeyCleanup();
      switch (result) {
        case StoredContent(:final message):
          _persisted.add(message);
        case Applied(:final event):
          _controlEvents.add(event);
        case Ignored():
          break;
      }
      await _acknowledge?.call(senderId, messageId);
    } catch (error) {
      // Leave failures queued on the server; never report corrupt ciphertext as delivered.
      _errors.add(error);
    }
  }

  /// Blocked sender, then the handler — inside a savepoint, so a handler's
  /// FormatException undoes only its own partial writes while the ratchet
  /// advance and the InboundLog row still commit (ack + drop).
  Future<InboundResult> _process(InboundContext ctx) async {
    if (await isBlocked(ctx.senderId)) return const Ignored();
    try {
      return await _db.transaction(() => _dispatcher.dispatch(ctx));
    } on FormatException catch (error) {
      // Id and reason only: FormatException.source (which may hold the
      // decrypted payload) is deliberately not forwarded.
      _errors.add(
        FormatException(
          'Dropped malformed message ${ctx.messageId}: '
          '${error.message}',
        ),
      );
      return const Ignored();
    }
  }

  Future<bool> _alreadyProcessed(
    String senderId,
    String messageId,
    String conversationId,
  ) async {
    final logged =
        await (_db.select(_db.inboundLog)..where(
              (l) =>
                  l.senderId.equals(senderId) & l.messageId.equals(messageId),
            ))
            .getSingleOrNull();
    if (logged != null) return true;
    // Rows stored before schema v4 have no InboundLog entry.
    final existing = await (_db.select(
      _db.messages,
    )..where((m) => m.id.equals(messageId))).getSingleOrNull();
    if (existing == null) return false;
    if (existing.senderId != senderId ||
        existing.conversationId != conversationId) {
      throw const FormatException('Conflicting message identity');
    }
    return true;
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    await _pending;
    await _persisted.close();
    await _controlEvents.close();
    await _errors.close();
  }
}
