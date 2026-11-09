import 'dart:async';

import 'package:calltype_core/devices/device_directory.dart';
import 'package:calltype_core/messaging/read_state.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:drift/drift.dart';

import '../devices/own_device_sender.dart';

/// BackupState key prefix of the read state of a conversation:
/// `read-upto:<conversationId>` = ms, the largest `readUpTo` this device
/// sent or received (spec 2026-11-09-auto-resend-read-sync, S4). Local
/// state, never backed up (S7).
const readUpToPrefix = 'read-upto:';

/// The stored read state of [conversationId], or null.
Future<int?> readUpToOf(AppDatabase db, String conversationId) async {
  final row =
      await (db.select(db.backupState)
            ..where((s) => s.key.equals('$readUpToPrefix$conversationId')))
          .getSingleOrNull();
  return row == null ? null : int.tryParse(row.value);
}

Future<void> _storeReadUpTo(
  AppDatabase db,
  String conversationId,
  int readUpTo,
) => db
    .into(db.backupState)
    .insertOnConflictUpdate(
      BackupStateCompanion.insert(
        key: '$readUpToPrefix$conversationId',
        value: '$readUpTo',
      ),
    );

/// Applies a `read-state` from another own device (S4). Runs inside the
/// inbox transaction. Returns true when the conversation is fully read
/// afterwards (its notification can go), false when the state was older
/// than what is known or the conversation does not exist here (ignored).
///
/// The unread count only goes DOWN: it becomes the number of incoming
/// messages after `readUpTo`, but never more than it was (a message read
/// here already stays read).
Future<bool> applyReadState(
  AppDatabase db,
  ReadStatePayload payload, {
  required String selfIdentityId,
}) async {
  final conversation = await (db.select(
    db.conversations,
  )..where((c) => c.id.equals(payload.conversationId))).getSingleOrNull();
  if (conversation == null) return false;
  final known = await readUpToOf(db, payload.conversationId);
  if (known != null && payload.readUpTo <= known) return false;
  await _storeReadUpTo(db, payload.conversationId, payload.readUpTo);
  final after = DateTime.fromMillisecondsSinceEpoch(payload.readUpTo);
  final count = db.messages.id.count();
  final unseen =
      await (db.selectOnly(db.messages)
            ..addColumns([count])
            ..where(
              db.messages.conversationId.equals(payload.conversationId) &
                  db.messages.senderId.equals(selfIdentityId).not() &
                  db.messages.type.equals('call-event').not() &
                  db.messages.deleted.equals(false) &
                  db.messages.createdAt.isBiggerThanValue(after),
            ))
          .map((row) => row.read(count) ?? 0)
          .getSingle();
  final unread = unseen < conversation.unreadCount
      ? unseen
      : conversation.unreadCount;
  if (unread != conversation.unreadCount) {
    await (db.update(db.conversations)
          ..where((c) => c.id.equals(payload.conversationId)))
        .write(ConversationsCompanion(unreadCount: Value(unread)));
  }
  return unread == 0;
}

/// Tells this identity's other devices when a conversation was read here
/// (spec S2), so they drop its unread count and notification. App-wide;
/// the open chat calls [conversationRead].
class ReadStateService {
  ReadStateService({
    required AppDatabase database,
    required OwnDeviceSender sender,
    required DeviceDirectory? Function() directory,
    required bool Function() foreground,
    String? Function()? openConversation,
    this.minInterval = const Duration(seconds: 3),
    DateTime Function()? clock,
  }) : _db = database,
       _sender = sender,
       _directory = directory,
       _foreground = foreground,
       _openConversation = openConversation,
       _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final OwnDeviceSender _sender;

  /// Null until onboarding opened the device directory.
  final DeviceDirectory? Function() _directory;
  final bool Function() _foreground;
  final String? Function()? _openConversation;
  final DateTime Function() _clock;

  /// At most one read state per conversation per this interval; a read
  /// inside it is sent when it ends (the newest state wins).
  final Duration minInterval;

  final _lastSent = <String, DateTime>{};
  final _trailing = <String, Timer>{};
  bool _disposed = false;

  /// The chat [conversationId] is open and was marked read. Only counts
  /// while the app is in the foreground (a chat left open in a background
  /// app is not read). Returns whether a read state went out now.
  Future<bool> conversationRead(String conversationId) async {
    if (_disposed || !_foreground()) return false;
    final last = _lastSent[conversationId];
    final now = _clock();
    if (last != null && now.difference(last) < minInterval) {
      _trailing[conversationId] ??= Timer(
        minInterval - now.difference(last),
        () {
          _trailing.remove(conversationId);
          unawaited(conversationRead(conversationId));
        },
      );
      return false;
    }
    return _send(conversationId);
  }

  /// Back in the foreground: the chat that is open now counts as read.
  Future<void> onResume() async {
    final open = _openConversation?.call();
    if (open != null) await conversationRead(open);
  }

  Future<bool> _send(String conversationId) async {
    final directory = _directory();
    if (directory == null) return false;
    final newest =
        await (_db.select(_db.messages)
              ..where(
                (m) =>
                    m.conversationId.equals(conversationId) &
                    m.senderId.equals(directory.selfIdentityId).not(),
              )
              ..orderBy([(m) => OrderingTerm.desc(m.createdAt)])
              ..limit(1))
            .getSingleOrNull();
    if (newest == null) return false;
    final readUpTo = newest.createdAt.millisecondsSinceEpoch;
    final known = await readUpToOf(_db, conversationId);
    if (known != null && readUpTo <= known) return false;
    // No companions: nothing to tell, and the hub refuses an empty fan-out.
    if ((await _sender.otherDevices()).isEmpty) return false;
    _lastSent[conversationId] = _clock();
    await _storeReadUpTo(_db, conversationId, readUpTo);
    // A failed send stays in the own-device outbox and goes out on the
    // next reconnect (OwnDeviceSender.resendPending).
    return _sender.send(
      readStateType,
      ReadStatePayload(
        conversationId: conversationId,
        readUpTo: readUpTo,
      ).encode(),
    );
  }

  void dispose() {
    _disposed = true;
    for (final timer in _trailing.values) {
      timer.cancel();
    }
    _trailing.clear();
  }
}
