import 'dart:async';
import 'dart:convert';

import 'package:calltype_core/storage/database.dart';
import 'package:drift/drift.dart';

import '../../l10n/app_localizations.dart';
import '../media/media_cleanup.dart';
import '../media/media_service.dart';
import 'chat_controller.dart' show controlTypes;
import 'message_inbox_service.dart' show tombstoneMessage;
import 'message_sender.dart';

/// Resends own messages that failed, without the user tapping "send again"
/// (spec 2026-11-09-auto-resend-read-sync, part 1). App-wide, not tied to
/// an open chat: a message that failed in a chat the user left is retried
/// too. Only while the app runs; there is no background work.
///
/// Triggers: [trigger] (hub connected again, app back in the foreground)
/// tries every eligible message at once; otherwise each message waits for
/// its own backoff ([backoff]). Every attempt goes through [MessageSender]
/// and with it through the same queue and the same stored outbox as a
/// manual retry, so a resend never re-encrypts what was already encrypted.
class ResendService {
  ResendService({
    required AppDatabase database,
    required MessageSender Function() sender,
    required String? Function() selfIdentityId,
    bool Function()? connected,
    AppLocalizations Function()? strings,
    DateTime Function()? clock,
    MediaService? media,
    Timer Function(Duration wait, void Function() callback)? timer,
  }) : _db = database,
       _newTimer = timer ?? Timer.new,
       _sender = sender,
       _self = selfIdentityId,
       _connected = connected,
       _strings = strings,
       _clock = clock ?? DateTime.now,
       _media = media;

  /// Waits after the 1st, 2nd, ... failure; the last one repeats (R2).
  static const backoff = [
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(minutes: 1),
    Duration(minutes: 5),
    Duration(minutes: 15),
  ];

  /// After this long since `createdAt` only the manual button is left (R3).
  static const giveUpAfter = Duration(hours: 24);

  /// A `sending` row this service has not seen fail is only taken over
  /// when it is this old: it is then a leftover of a killed app, not a
  /// first send that is still running (R1).
  static const orphanAge = Duration(minutes: 2);

  final AppDatabase _db;
  final MessageSender Function() _sender;
  final String? Function() _self;
  final bool Function()? _connected;
  final AppLocalizations Function()? _strings;
  final DateTime Function() _clock;
  final MediaService? _media;

  /// Starts the backoff timer; tests drive [runDue] with a fake clock
  /// instead.
  final Timer Function(Duration wait, void Function() callback) _newTimer;

  /// Automatic failures in a row per message, and when it is due again.
  final _failures = <String, int>{};
  final _dueAt = <String, DateTime>{};
  Timer? _timer;
  Future<void>? _running;
  bool _again = false;
  bool _againAll = false;
  bool _disposed = false;

  /// Whether a failed message created at [createdAt] is still inside the
  /// window of automatic resends. The chat shows such a message as
  /// "sending" instead of failed (R8).
  bool withinWindow(DateTime createdAt) =>
      _clock().difference(createdAt) < giveUpAfter;

  /// When [messageId] is due for its next automatic attempt (tests, UI).
  DateTime? dueAt(String messageId) => _dueAt[messageId];

  /// Reports a send attempt made elsewhere (the chat screen). A [manual]
  /// attempt resets the backoff (R3): if it failed, the next automatic
  /// try comes after the first step again.
  void attempted(String messageId, SendOutcome outcome, {bool manual = true}) {
    if (_disposed) return;
    switch (outcome.status) {
      case SendStatus.sent:
      case SendStatus.permanent:
        _forget(messageId);
      case SendStatus.skipped:
        break;
      case SendStatus.transient:
        final failures = manual ? 1 : (_failures[messageId] ?? 0) + 1;
        _failures[messageId] = failures;
        _dueAt[messageId] = _clock().add(
          backoff[(failures - 1).clamp(0, backoff.length - 1)],
        );
    }
    _arm();
  }

  /// Hub connected again or app back in the foreground: every eligible
  /// message is tried now, whatever its backoff says.
  Future<void> trigger() => runDue(all: true);

  /// Tries every message that is due ([all]: every eligible one). Two calls
  /// at once share one pass, so a message is never sent twice in parallel
  /// (and [MessageSender] refuses a second attempt of the same id anyway).
  Future<void> runDue({bool all = false}) {
    if (_disposed) return Future.value();
    final running = _running;
    if (running != null) {
      _again = true;
      _againAll = _againAll || all;
      return running;
    }
    final pass = _pass(all).whenComplete(() {
      _running = null;
      if (_again && !_disposed) {
        final nextAll = _againAll;
        _again = false;
        _againAll = false;
        unawaited(runDue(all: nextAll));
      } else {
        _arm();
      }
    });
    return _running = pass;
  }

  Future<void> _pass(bool all) async {
    final self = _self();
    if (self == null) return;
    // Offline every attempt fails at once; the reconnect trigger comes.
    final connected = _connected;
    if (connected != null && !connected()) return;
    final rows =
        await (_db.select(_db.messages)..where(
              (m) =>
                  m.senderId.equals(self) &
                  m.status.isIn(const ['failed', 'sending']),
            ))
            .get();
    final permanent = {
      for (final row in await (_db.select(
        _db.backupState,
      )..where((s) => s.key.like('$sendFailPrefix%'))).get())
        row.key.substring(sendFailPrefix.length),
    };
    final present = {for (final r in rows) r.id};
    _failures.removeWhere((id, _) => !present.contains(id));
    _dueAt.removeWhere((id, _) => !present.contains(id));
    final registry = OutboxRegistry.forDatabase(_db);
    for (final row in rows) {
      if (_disposed) return;
      if (permanent.contains(row.id) || registry.busy(row.id)) continue;
      final now = _clock();
      final age = now.difference(row.createdAt);
      if (age >= giveUpAfter) {
        await _giveUp(row);
        continue;
      }
      if (row.status == 'sending' &&
          !_failures.containsKey(row.id) &&
          age < orphanAge) {
        continue;
      }
      final due = _dueAt[row.id];
      if (!all && due != null && due.isAfter(now)) continue;
      if (controlTypes.contains(row.type)) {
        await _resendOrphanControl(row);
      } else {
        final outcome = await _sender().send(
          row.id,
          localizations: _strings?.call(),
        );
        attempted(row.id, outcome, manual: false);
      }
    }
  }

  /// R3: the window is over. The row stays (or becomes) `failed` with the
  /// manual button; a leftover control row is dropped, its local effect
  /// stays as it was applied.
  Future<void> _giveUp(Message row) async {
    _forget(row.id);
    await _db.transaction(() async {
      if (controlTypes.contains(row.type)) {
        await dropControlRow(_db, row.id);
        return;
      }
      await (_db.update(_db.messages)..where((m) => m.id.equals(row.id))).write(
        const MessagesCompanion(status: Value('failed')),
      );
      await _db
          .into(_db.backupState)
          .insertOnConflictUpdate(
            BackupStateCompanion.insert(
              key: '$sendFailPrefix${row.id}',
              value: sendFailExpired,
            ),
          );
    });
  }

  /// A transient control row (edit, delete, reaction, pin, vote) that no
  /// live flow holds: the app was killed between creating and dropping it
  /// (R7). Reactions, pins and votes were applied locally before the send;
  /// an edit or a delete changes the local copy only after it went out, so
  /// that last step is done here. The row is dropped once sent or when the
  /// send cannot succeed.
  Future<void> _resendOrphanControl(Message row) async {
    final editOf = row.type == 'edit' ? await _editTargetOf(row.id) : null;
    final outcome = await _sender().send(row.id);
    switch (outcome.status) {
      case SendStatus.skipped:
        return;
      case SendStatus.transient:
        attempted(row.id, outcome, manual: false);
        return;
      case SendStatus.permanent:
        _forget(row.id);
        await dropControlRow(_db, row.id);
        return;
      case SendStatus.sent:
        _forget(row.id);
    }
    Message? deletedMedia;
    await _db.transaction(() async {
      final target = row.type == 'delete'
          ? row.body
          : row.type == 'edit'
          ? editOf
          : null;
      final original = target == null
          ? null
          : await (_db.select(
              _db.messages,
            )..where((m) => m.id.equals(target))).getSingleOrNull();
      if (original != null &&
          original.senderId == row.senderId &&
          original.conversationId == row.conversationId) {
        if (row.type == 'delete') {
          await tombstoneMessage(_db, original.id);
          if (original.type == 'media') deletedMedia = original;
        } else {
          await (_db.update(
            _db.messages,
          )..where((m) => m.id.equals(original.id))).write(
            MessagesCompanion(
              body: Value(row.body),
              editedAt: Value(row.createdAt),
            ),
          );
        }
      }
      await dropControlRow(_db, row.id);
    });
    final media = deletedMedia;
    if (media != null) {
      await deleteUnreferencedMedia(
        _db,
        _media ?? MediaService.instance,
        media.body,
        media.id,
      );
    }
  }

  /// The message an orphan `edit` row changes: in `extra:` until the first
  /// attempt wrote the outbox, then inside the outbox payload.
  Future<String?> _editTargetOf(String controlId) async {
    final rows =
        await (_db.select(_db.backupState)..where(
              (s) => s.key.isIn(['extra:$controlId', 'outbox:$controlId']),
            ))
            .get();
    for (final row in rows) {
      try {
        final json = jsonDecode(row.value) as Map<String, dynamic>;
        final source = row.key.startsWith('extra:')
            ? json
            : jsonDecode((json['fanout'] as Map)['payload'] as String) as Map;
        final target = source['editOf'];
        if (target is String) return target;
      } catch (_) {
        // A damaged entry names no target; the edit then only goes out.
      }
    }
    return null;
  }

  void _forget(String messageId) {
    _failures.remove(messageId);
    _dueAt.remove(messageId);
  }

  /// One timer for the earliest due message.
  void _arm() {
    _timer?.cancel();
    _timer = null;
    if (_disposed || _dueAt.isEmpty || _running != null) return;
    final next = _dueAt.values.reduce((a, b) => a.isBefore(b) ? a : b);
    var wait = next.difference(_clock());
    if (wait.isNegative) wait = Duration.zero;
    _timer = _newTimer(wait, () => unawaited(runDue()));
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }
}
