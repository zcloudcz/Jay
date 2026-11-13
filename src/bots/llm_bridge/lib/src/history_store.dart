import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:calltype_bot/calltype_bot.dart' show EncryptedFileStore;

import 'provider.dart';

/// Conversation memory and the greeting marker, in ONE file encrypted with
/// the bot's `BOT_STORE_KEY` (AES-256-GCM, the identity store's format).
///
/// WHY not the runtime's SQLite (the spec's first idea, `backupState`
/// rows): that database is plaintext on disk (calltype_bot README), and
/// chat history is exactly the content E2E protects; the identity store's
/// encryption is the right tier. WHY a separate file and not the identity
/// store itself: the runtime owns that file and its object; a second
/// writer of the same path would race it. Deleting `<store>.llm` forgets
/// every chat and nothing else.
class HistoryStore {
  HistoryStore._(this._store, this.cap);

  final EncryptedFileStore _store;

  /// Max messages remembered per conversation (`LLM_HISTORY_MESSAGES`).
  final int cap;

  /// Opens [path] with [key] (`BOT_STORE_KEY`). A file that cannot be
  /// decrypted is moved aside (`.corrupt`) and a fresh one started: losing
  /// chat memory is acceptable, refusing to start over it is not.
  static Future<HistoryStore> open(
    String path,
    Uint8List key, {
    required int cap,
    void Function(String) log = _noLog,
  }) async {
    try {
      return HistoryStore._(await EncryptedFileStore.open(path, key), cap);
    } on StateError catch (e) {
      log(
        'History store $path unusable (${e.message}); starting empty, old file kept as .corrupt.',
      );
      await File(path).rename('$path.corrupt');
      return HistoryStore._(await EncryptedFileStore.open(path, key), cap);
    }
  }

  static void _noLog(String _) {}

  static String _historyKey(String conversationId) =>
      'history:${conversationId.toLowerCase()}';

  /// The remembered turns of [conversationId], oldest first.
  Future<List<ChatTurn>> history(String conversationId) async {
    final raw = await _store.read(_historyKey(conversationId));
    if (raw == null) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return [for (final item in list) ?ChatTurn.fromJson(item)];
    } on FormatException {
      return const [];
    }
  }

  /// Appends [turns] and keeps only the last [cap] messages.
  ///
  /// [keepOverflow] (history summary, spec 2026-11-13-group-topics T5):
  /// keep up to twice [cap] so the caller can fold the overflow into the
  /// summary and then [replace] the list; the bound only matters if the
  /// caller never does.
  Future<void> append(
    String conversationId,
    List<ChatTurn> turns, {
    bool keepOverflow = false,
  }) async {
    if (cap == 0) return;
    final all = [...await history(conversationId), ...turns];
    final limit = keepOverflow ? cap * 2 : cap;
    await replace(
      conversationId,
      all.length <= limit ? all : all.sublist(all.length - limit),
    );
  }

  /// Stores exactly [turns] as the history of [conversationId].
  Future<void> replace(String conversationId, List<ChatTurn> turns) =>
      _store.write(
        _historyKey(conversationId),
        jsonEncode([for (final t in turns) t.toJson()]),
      );

  static String _summaryKey(String conversationId) =>
      'summary:${conversationId.toLowerCase()}';

  /// The folded summary of the older part of [conversationId] (T5), or
  /// null when there is none.
  Future<String?> summary(String conversationId) async {
    final raw = await _store.read(_summaryKey(conversationId));
    return raw == null || raw.trim().isEmpty ? null : raw;
  }

  Future<void> setSummary(String conversationId, String summary) =>
      _store.write(_summaryKey(conversationId), summary);

  /// Forgets [conversationId] (`/new`): its history and its summary.
  Future<void> reset(String conversationId) async {
    await _store.delete(_historyKey(conversationId));
    await _store.delete(_summaryKey(conversationId));
  }

  /// Whether the one-time greeting went to [handle] already.
  Future<bool> greeted(String handle) async =>
      await _store.read('greeted:${handle.toUpperCase()}') != null;

  Future<void> markGreeted(String handle) => _store.write(
    'greeted:${handle.toUpperCase()}',
    DateTime.now().toUtc().toIso8601String(),
  );
}
