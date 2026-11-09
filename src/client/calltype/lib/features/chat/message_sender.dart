import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Locale;

import 'package:calltype_core/crypto/group_cipher.dart';
import 'package:calltype_core/crypto/session_manager.dart';
import 'package:calltype_core/devices/device_directory.dart';
import 'package:calltype_core/devices/fanout_sender.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/network/organization_api.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';

import '../../core/network/signalr_client.dart';
import '../../l10n/app_localizations.dart';
import '../media/media_message.dart';
import '../media/media_service.dart';
import 'message_inbox_service.dart' show MessageProcessingQueue;
import 'polls.dart';

/// BackupState key prefix of an own message that must NOT be resent
/// automatically (spec 2026-11-09-auto-resend-read-sync, R3/R4):
/// `sendfail:<messageId>` = the reason. The bubble then shows the manual
/// "send again" button. Local only, never backed up.
const sendFailPrefix = 'sendfail:';

/// Reason stored under [sendFailPrefix] when the 24 h window of automatic
/// resends ended (R3).
const sendFailExpired = 'expired';

/// How one send attempt ended.
enum SendStatus {
  /// Delivered to the hub; the row is `sent`.
  sent,

  /// Nothing was attempted: the row is gone, not ours, already sent, or
  /// another attempt for it is running.
  skipped,

  /// Failed for a reason that may go away (network, hub down, timeout, 5xx,
  /// a device list that stayed stale): the row is `failed`, an automatic
  /// resend may follow.
  transient,

  /// Failed for a reason a resend cannot fix: the row is `failed` and
  /// remembered under [sendFailPrefix].
  permanent,
}

class SendOutcome {
  const SendOutcome(this.status, {this.error, this.reason});

  static const sent = SendOutcome(SendStatus.sent);
  static const skipped = SendOutcome(SendStatus.skipped);

  final SendStatus status;

  /// What the attempt threw (hub errors carry their code in the text).
  final Object? error;

  /// The stored reason of a [SendStatus.permanent] failure.
  final String? reason;
}

/// A send that can never succeed as it is (the conversation is gone, this
/// device may not send there, the message itself is invalid).
class PermanentSendError implements Exception {
  const PermanentSendError(this.reason);
  final String reason;

  @override
  String toString() => 'PermanentSendError: $reason';
}

/// Hub error texts (see MessengerHub) after which an automatic resend is
/// pointless: they depend on membership, organization policy or the message
/// itself, never on the network.
const _permanentHubErrors = {
  'audit_recipient_missing': 'audit_recipient_missing',
  'business_conversation_required': 'business_conversation_required',
  'not_a_business_member': 'not_a_business_member',
  'fanout_too_many_devices': 'fanout_too_many_devices',
  'Sender and recipients must be group members': 'not_a_member',
  'Group message exceeds maximum member count': 'too_many_members',
  'Invalid encrypted payload': 'invalid_payload',
  'Conversation must be a device or group UUID': 'invalid_conversation',
};

/// The reason [error] makes a send permanently impossible, or null when a
/// later attempt may succeed. WHY `auditor_unavailable` is NOT here: the
/// auditor being down is an availability problem (the hub fails closed
/// until it is back), exactly what an automatic resend is for.
String? permanentSendFailure(Object error) {
  if (error is MediaCancelled) return 'media_cancelled';
  if (error is PermanentSendError) return error.reason;
  if (error is DioException) {
    final code = error.response?.statusCode;
    // 401 is refreshed by the client, 408 and 429 pass with time.
    if (code != null &&
        code >= 400 &&
        code < 500 &&
        code != 401 &&
        code != 408 &&
        code != 429) {
      return 'http_$code';
    }
    return null;
  }
  final text = error.toString();
  for (final MapEntry(:key, :value) in _permanentHubErrors.entries) {
    if (text.contains(key)) return value;
  }
  return null;
}

/// Which own messages have a send running or are owned by a flow that is
/// still deciding about them, per device database (like
/// [MessageProcessingQueue]). Lets the chat screen, the automatic resend
/// and a manual tap never send the same message twice at once (R5).
class OutboxRegistry {
  static final _registries = Expando<OutboxRegistry>();
  static OutboxRegistry forDatabase(AppDatabase db) =>
      _registries[db] ??= OutboxRegistry();

  final _inFlight = <String>{};
  final _held = <String>{};

  /// A send of [messageId] is running, or a control flow holds it.
  bool busy(String messageId) =>
      _inFlight.contains(messageId) || _held.contains(messageId);

  /// A transient control row (reaction, pin, vote, edit, delete) belongs to
  /// the flow that created it until that flow dropped it: it restores or
  /// finishes the local state itself, so no automatic resend may touch it.
  void hold(String messageId) => _held.add(messageId);
  void release(String messageId) => _held.remove(messageId);
}

/// `mediaup:<messageId>`: where the local copy of an unfinished upload is
/// and whether it finished (media contract 4.1).
Future<void> storeUploadState(
  AppDatabase db,
  String messageId, {
  required String folder,
  bool uploaded = false,
}) => db
    .into(db.backupState)
    .insertOnConflictUpdate(
      BackupStateCompanion.insert(
        key: 'mediaup:$messageId',
        value: jsonEncode({'folder': folder, 'uploaded': uploaded}),
      ),
    );

/// Removes a transient control row with everything that belongs to it.
Future<void> dropControlRow(AppDatabase db, String controlId) async {
  await (db.delete(db.messages)..where((m) => m.id.equals(controlId))).go();
  await (db.delete(db.backupState)..where(
        (s) => s.key.isIn([
          'outbox:$controlId',
          'extra:$controlId',
          '$sendFailPrefix$controlId',
        ]),
      ))
      .go();
}

/// The one send path of own chat messages (spec R9): upload of a media
/// row, encryption into the stored outbox (`outbox:<id>`, resent byte for
/// byte), fan-out with stale repair, the business fallback. Not bound to
/// a conversation or a screen, so the chat screen and the app-wide
/// [ResendService] share it. Stateless apart from its references.
class MessageSender {
  MessageSender({
    required AppDatabase database,
    required SignalRClient signalRClient,
    required SessionManager sessionManager,
    required ApiClient apiClient,
    required DeviceDirectory directory,
    void Function(Set<String> required)? onStale,
    void Function(String deviceId)? onMissingOwnDevice,
    MediaService? media,
  }) : _db = database,
       _signalR = signalRClient,
       _sessions = sessionManager,
       _api = apiClient,
       _directory = directory,
       _onStale = onStale,
       media = media ?? MediaService.instance,
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
           () =>
               unawaited(_reportIfOwn(deviceId, directory, onMissingOwnDevice)),
         ),
       );

  final AppDatabase _db;
  final SignalRClient _signalR;
  final SessionManager _sessions;
  final ApiClient _api;
  final DeviceDirectory _directory;
  final FanoutSender _fanout;
  final MediaService media;

  /// Told about every `device_list_stale` answer. Must not await anything
  /// that runs in MessageProcessingQueue: it is called from inside it.
  final void Function(Set<String> required)? _onStale;

  /// Rounds of "send; on device_list_stale repair the envelopes and resend".
  /// Bounded: a server that keeps answering stale produces a visible failure,
  /// not a loop.
  static const _maxFanoutRounds = 3;

  static final _english = lookupAppLocalizations(const Locale('en'));

  String get _me => _directory.selfIdentityId;

  static Future<void> _reportIfOwn(
    String deviceId,
    DeviceDirectory directory,
    void Function(String deviceId)? report,
  ) async {
    if (await directory.identityOf(deviceId) == directory.selfIdentityId) {
      report?.call(deviceId);
    }
  }

  /// Sends (again) the own message [messageId]. A media row first finishes
  /// its upload, outside the processing queue (see [_prepareMedia]).
  /// [localizations] writes the fallback text old clients show for media
  /// and polls (English when null). Never throws.
  Future<SendOutcome> send(
    String messageId, {
    AppLocalizations? localizations,
  }) async {
    final registry = OutboxRegistry.forDatabase(_db);
    if (!registry._inFlight.add(messageId)) return SendOutcome.skipped;
    try {
      final prepared = await _prepareMedia(messageId);
      if (prepared != null) return prepared;
      return await _sendQueued(messageId, localizations ?? _english);
    } catch (e) {
      // Only reachable for database errors outside the guarded parts.
      return SendOutcome(SendStatus.transient, error: e);
    } finally {
      registry._inFlight.remove(messageId);
    }
  }

  /// Runs (or resumes) the upload of an own media row before it can be
  /// sent. Deliberately OUTSIDE MessageProcessingQueue: an upload takes
  /// minutes and must not block decrypting incoming messages. Returns null
  /// when the message may be sent now, else how this attempt ended.
  Future<SendOutcome?> _prepareMedia(String messageId) async {
    final message = await (_db.select(
      _db.messages,
    )..where((m) => m.id.equals(messageId))).getSingleOrNull();
    if (message == null || message.type != 'media') return null;
    final state = await _loadUploadState(messageId);
    if (state == null || state['uploaded'] == true) return null;
    if (message.senderId != _me ||
        (message.status != 'failed' && message.status != 'sending')) {
      return SendOutcome.skipped;
    }
    if (media.isUploading(messageId)) return SendOutcome.skipped;
    final draft = MediaInfo.tryDecode(message.body);
    final folder = state['folder'];
    if (draft == null || folder is! String) {
      return _failed(messageId, const PermanentSendError('invalid_media'));
    }
    await _status(messageId, 'sending');
    try {
      final done = await media.upload(
        messageId,
        draft,
        folder: folder,
        persist: (info, folder) => _db.transaction(() async {
          await (_db.update(_db.messages)..where((m) => m.id.equals(messageId)))
              .write(MessagesCompanion(body: Value(info.encode())));
          await storeUploadState(_db, messageId, folder: folder);
        }),
      );
      await _db.transaction(() async {
        await (_db.update(_db.messages)..where((m) => m.id.equals(messageId)))
            .write(MessagesCompanion(body: Value(done.encode())));
        await storeUploadState(_db, messageId, folder: done.id, uploaded: true);
      });
      return null;
    } catch (e) {
      // A cancel is permanent (the user stopped it), see permanentSendFailure.
      return _failed(messageId, e);
    }
  }

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

  /// Marks the row failed and remembers a permanent reason (a transient
  /// failure clears an old one: a manual retry got further than before).
  Future<SendOutcome> _failed(String messageId, Object error) async {
    final reason = permanentSendFailure(error);
    await _db.transaction(() async {
      await _status(messageId, 'failed');
      if (reason == null) {
        await (_db.delete(
          _db.backupState,
        )..where((s) => s.key.equals('$sendFailPrefix$messageId'))).go();
      } else {
        await _db
            .into(_db.backupState)
            .insertOnConflictUpdate(
              BackupStateCompanion.insert(
                key: '$sendFailPrefix$messageId',
                value: reason,
              ),
            );
      }
    });
    return SendOutcome(
      reason == null ? SendStatus.transient : SendStatus.permanent,
      error: error,
      reason: reason,
    );
  }

  Future<SendOutcome> _sendQueued(
    String messageId,
    AppLocalizations l10n,
  ) => MessageProcessingQueue.forDatabase(_db).run(() async {
    final message = await (_db.select(
      _db.messages,
    )..where((m) => m.id.equals(messageId))).getSingleOrNull();
    // A row that is `sent` or newer is never resent (R5).
    if (message == null ||
        message.senderId != _me ||
        (message.status != 'failed' && message.status != 'sending')) {
      return SendOutcome.skipped;
    }
    final conversationId = message.conversationId;
    await _status(messageId, 'sending');
    try {
      var stored = await (_db.select(
        _db.backupState,
      )..where((s) => s.key.equals('outbox:$messageId'))).getSingleOrNull();
      if (stored == null) {
        final conversation = await (_db.select(
          _db.conversations,
        )..where((c) => c.id.equals(conversationId))).getSingleOrNull();
        if (conversation == null) {
          throw const PermanentSendError('conversation_missing');
        }
        final groupId = conversation.type == 'group' ? conversationId : null;
        // Business conversations stay on the per-member group call from the
        // primary: KB2 auditor rules are defined over member devices and the
        // hub refuses fan-out there. v1 keeps companions out of them.
        final business = conversation.organizationId != null;
        if (business && _directory.isCompanion) {
          throw const PermanentSendError('companion_business');
        }
        final recipients = groupId == null
            ? [conversationId]
            : (await _api.getGroupMembers(
                groupId,
              )).where((id) => id != _me).toList();
        if (recipients.isEmpty) {
          throw const PermanentSendError('no_recipients');
        }
        // Contract M7: media goes out as `text` with a fallback body for old
        // clients plus the `media` object new clients read.
        final mediaInfo = message.type == 'media'
            ? MediaInfo.tryDecode(message.body)
            : null;
        if (message.type == 'media' &&
            (mediaInfo == null || mediaInfo.isDraft)) {
          throw const PermanentSendError('media_not_uploaded');
        }
        // Spec 2026-11-08-chat-extras: a poll goes out the same way, as
        // `text` with a fallback body plus the `poll` object.
        final poll = message.type == pollMessageType
            ? PollPayload.tryDecode(message.body)
            : null;
        if (message.type == pollMessageType && poll == null) {
          throw const PermanentSendError('invalid_poll');
        }
        final payload = jsonEncode({
          'v': 1,
          'id': messageId,
          'body': mediaInfo != null
              ? mediaFallbackBody(l10n, mediaInfo)
              : poll != null
              ? poll.fallbackText(l10n.pollFallbackUpdate)
              : message.body,
          'type': mediaInfo == null && poll == null ? message.type : 'text',
          if (mediaInfo != null) 'media': mediaInfo.toJson(),
          if (poll != null) pollKey: poll.toJson(),
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
              (s) => s.key.isIn([
                'outbox:$messageId',
                'mediaup:$messageId',
                '$sendFailPrefix$messageId',
              ]),
            ))
            .go();
      });
      return SendOutcome.sent;
    } catch (e) {
      return _failed(messageId, e);
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
    final payload = fanout['payload'] as String;
    try {
      await _fanout.deliver(
        envelopes: envelopes,
        identityIds: (fanout['identityIds'] as List).cast<String>(),
        payload: payload,
        maxRounds: _maxFanoutRounds,
        onStale: _onStale,
        send: (current) => groupId == null
            ? _signalR.sendDirectFanout(
                (fanout['identityIds'] as List).single as String,
                current,
                messageId: messageId,
              )
            : _signalR.sendGroupFanout(groupId, current, messageId: messageId),
        // The hub computes `required` from the CURRENT membership, but the
        // stored identityIds are from the first attempt. Without this a
        // member added before a retry stays "unverified" for good and every
        // retry fails. The union keeps removed members out of nothing:
        // reconcile already trims envelopes the hub no longer wants. Same
        // trust as the first send (the member list comes from the server).
        identityIdsFor: groupId == null
            ? null
            : (ids) async => {
                ...ids,
                ...(await _api.getGroupMembers(
                  groupId,
                )).where((id) => id != _me),
              }.toList(),
        // A crash in between only loses envelopes nobody has received;
        // encrypting those again is harmless.
        persist: (current, ids) =>
            (_db.update(
              _db.backupState,
            )..where((s) => s.key.equals('outbox:$messageId'))).write(
              BackupStateCompanion(
                value: Value(
                  jsonEncode({
                    ...outbox,
                    'envelopes': current,
                    'fanout': {...fanout, 'identityIds': ids},
                  }),
                ),
              ),
            ),
      );
    } catch (e) {
      if (groupId != null &&
          e.toString().contains('fanout_unsupported_in_business_group')) {
        await _sendBusinessFallback(messageId, groupId, payload);
        return;
      }
      rethrow;
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
    if (_directory.isCompanion) {
      throw const PermanentSendError('companion_business');
    }
    // Fills the cached organizationId, so the next send goes straight to the
    // business path (and the banner appears).
    await syncBusinessInfo(groupId);
    final recipients = (await _api.getGroupMembers(
      groupId,
    )).where((id) => id != _me).toList();
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
      await (_db.update(
        _db.backupState,
      )..where((s) => s.key.equals('outbox:$messageId'))).write(
        BackupStateCompanion(
          value: Value(
            jsonEncode({'groupId': groupId, 'envelopes': envelopes}),
          ),
        ),
      );
    });
    await _signalR.sendGroupMessage(groupId, envelopes, messageId: messageId);
  }

  /// Backfills the local `organizationId`/`organizationName` cache of the
  /// group [conversationId] from the server, once. Best effort: a network
  /// error leaves it unknown.
  Future<void> syncBusinessInfo(String conversationId) async {
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
      if (!info.isBusiness) return;
      await (_db.update(
        _db.conversations,
      )..where((c) => c.id.equals(conversationId))).write(
        ConversationsCompanion(
          organizationId: Value(info.organizationId),
          organizationName: Value(info.organizationName),
        ),
      );
    } catch (_) {
      // Best-effort cache warm-up; the banner simply won't show yet.
    }
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
}
