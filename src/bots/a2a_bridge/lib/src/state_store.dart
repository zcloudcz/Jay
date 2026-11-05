import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// What the bridge remembers per Jay conversation.
class ConversationState {
  const ConversationState({this.contextId, this.taskId});

  /// The agent's conversation (A2A `contextId`): keeps the agent's memory of
  /// this chat across messages and bridge restarts.
  final String? contextId;

  /// An `input-required` task waiting for the user's next message.
  final String? taskId;

  bool get isEmpty => contextId == null && taskId == null;

  Map<String, dynamic> toJson() => {'contextId': ?contextId, 'taskId': ?taskId};

  static ConversationState fromJson(Object? json) {
    if (json is! Map) return const ConversationState();
    String? s(Object? v) => v is String && v.isNotEmpty ? v : null;
    return ConversationState(
      contextId: s(json['contextId']),
      taskId: s(json['taskId']),
    );
  }
}

/// Conversation id -> [ConversationState], persisted as one JSON file
/// (`A2A_STATE_PATH`).
///
/// WHY a file and not the bot's SQLite: the runtime owns that schema
/// (calltype_core's drift tables); a sidecar JSON keeps the bridge
/// independent of it and is trivially inspectable or deletable by an
/// operator ("forget all agent conversations" = delete the file).
///
/// WHY atomic writes (temp file + rename): a crash or `docker stop` in the
/// middle of a plain overwrite would leave a truncated file, and every
/// conversation would silently lose its agent context.
class StateStore {
  StateStore._(this.path, this._data);

  final String path;
  final Map<String, ConversationState> _data;

  /// Writes are chained so two conversations finishing at once cannot
  /// interleave their temp-file writes.
  Future<void> _writes = Future.value();

  /// Loads [path]; a missing file is an empty store. A corrupt file is moved
  /// aside (`.corrupt`) rather than crashing the bridge in a restart loop.
  static Future<StateStore> open(
    String path, {
    void Function(String) log = _noLog,
  }) async {
    final file = File(path);
    final data = <String, ConversationState>{};
    if (await file.exists()) {
      try {
        final json = jsonDecode(await file.readAsString());
        final conversations = json is Map ? json['conversations'] : null;
        if (conversations is Map) {
          conversations.forEach((key, value) {
            final state = ConversationState.fromJson(value);
            if (key is String && !state.isEmpty) data[key] = state;
          });
        }
      } on FormatException catch (e) {
        log(
          'A2A state $path is corrupt ($e); starting empty, old file kept as .corrupt.',
        );
        await file.rename('$path.corrupt');
      }
    }
    return StateStore._(path, data);
  }

  static void _noLog(String _) {}

  static String _key(String conversationId) => conversationId.toLowerCase();

  ConversationState get(String conversationId) =>
      _data[_key(conversationId)] ?? const ConversationState();

  /// Replaces the state of [conversationId] and persists.
  Future<void> set(String conversationId, ConversationState state) {
    final key = _key(conversationId);
    state.isEmpty ? _data.remove(key) : _data[key] = state;
    return _persist();
  }

  /// Forgets [conversationId] (the `/reset` command).
  Future<void> reset(String conversationId) =>
      set(conversationId, const ConversationState());

  Future<void> _persist() {
    // Snapshot NOW so the chained write stores this call's view.
    final snapshot = jsonEncode({
      'version': 1,
      'conversations': {for (final e in _data.entries) e.key: e.value.toJson()},
    });
    final next = _writes.then((_) async {
      final tmp = File('$path.tmp');
      await tmp.parent.create(recursive: true);
      await tmp.writeAsString(snapshot, flush: true);
      await tmp.rename(path);
    });
    // A failed write must not poison every later one.
    _writes = next.catchError((Object _) {});
    return next;
  }
}
