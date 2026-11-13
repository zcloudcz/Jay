import '../calltype_bot.dart';

/// Helpers for bridges that talk to a backend with its own memory (Hermes,
/// A2A agents), spec 2026-11-13-group-topics T2/T3. Shared here like
/// [BotTalkPolicy] so both bridges follow one implementation.

/// Who wrote a group [message], for a prompt line: handle, display name or
/// identity id, with ` (bot)` for bots.
String groupSenderLabel(BotMessage message) {
  final name =
      message.senderHandle ?? message.senderDisplayName ?? message.senderId;
  return message.senderIsBot == true ? '$name (bot)' : name;
}

/// The text of a context [message] for a prompt: a file is named (never
/// downloaded for context), with its caption.
String contextTextOf(BotMessage message) {
  final attachment = message.attachment;
  if (attachment == null) return message.text;
  return [
    '[file: ${attachment.name}]',
    if (attachment.caption != null) attachment.caption!,
  ].join(' ');
}

/// What a group said between two turns of the bot (T3), per conversation,
/// in memory: the newest [maxEntries] lines within [maxChars] characters.
///
/// WHY in memory: the backend keeps its own history; this only bridges the
/// gap until the next turn. A restart loses unanswered context (spec
/// "Limits").
class GroupContextBuffer {
  GroupContextBuffer({this.maxEntries = 50, this.maxChars = 8000});

  final int maxEntries;
  final int maxChars;
  final _lines = <String, List<String>>{};

  /// Adds one line `- <label>: <text>` (newlines folded, a single line cut
  /// to [maxChars]) and drops the oldest beyond the limits.
  void add(String conversationId, String label, String text) {
    final body = text.trim().replaceAll(RegExp(r'\s*\n\s*'), ' / ');
    if (body.isEmpty) return;
    var line = '- $label: $body';
    if (line.length > maxChars) line = line.substring(0, maxChars);
    final lines = _lines.putIfAbsent(conversationId.toLowerCase(), () => []);
    lines.add(line);
    // Joined length (lines + newlines); the newest line always stays.
    var total = lines.fold<int>(-1, (n, l) => n + l.length + 1);
    while (lines.length > 1 &&
        (lines.length > maxEntries || total > maxChars)) {
      total -= lines.removeAt(0).length + 1;
    }
  }

  /// Adds [message] (see [groupSenderLabel], [contextTextOf]).
  void addMessage(BotMessage message) => add(
    message.conversationId,
    groupSenderLabel(message),
    contextTextOf(message),
  );

  /// The buffered lines of [conversationId] as
  /// `[Meanwhile in the group:\n- a: b\n...]`, then cleared; null when none.
  String? take(String conversationId) {
    final lines = _lines.remove(conversationId.toLowerCase());
    if (lines == null || lines.isEmpty) return null;
    return '[Meanwhile in the group:\n${lines.join('\n')}]';
  }

  /// The buffered lines of [conversationId], oldest first (for tests).
  List<String> peek(String conversationId) =>
      List.unmodifiable(_lines[conversationId.toLowerCase()] ?? const []);
}

/// When to tell a backend the group topic (T2): on the first turn of a
/// conversation in this bridge run, and whenever the version differs from
/// the last one sent. The last sent version is persisted through [load] /
/// [save] (the bridge's store), so the comparison survives a restart.
class GroupTopicAnnouncer {
  GroupTopicAnnouncer({
    required Future<int?> Function(String conversationId) load,
    required Future<void> Function(String conversationId, int version) save,
  }) : _load = load,
       _save = save;

  final Future<int?> Function(String conversationId) _load;
  final Future<void> Function(String conversationId, int version) _save;
  final _sentThisRun = <String, int>{};

  /// A [GroupTopicAnnouncer] over [CallTypeBot.readBridgeState].
  factory GroupTopicAnnouncer.inBotStore(CallTypeBot bot) {
    String key(String c) => 'topic-sent:${c.toLowerCase()}';
    return GroupTopicAnnouncer(
      load: (c) async => int.tryParse(await bot.readBridgeState(key(c)) ?? ''),
      save: (c, v) => bot.writeBridgeState(key(c), '$v'),
    );
  }

  /// The topic to send with this turn of [message], or null: the topic
  /// text, or '' when the admins cleared one the backend was told about.
  /// Records it as sent.
  Future<String?> takeFor(BotMessage message) => message.isGroup
      ? take(
          message.conversationId,
          version: message.groupTopicVersion,
          topic: message.groupTopic,
        )
      : Future.value();

  /// [takeFor] on plain values: [version] null = the bot has no topic for
  /// this group, [topic] null or '' = none / cleared.
  Future<String?> take(
    String conversationId, {
    required int? version,
    String? topic,
  }) async {
    if (version == null) return null;
    final key = conversationId.toLowerCase();
    final inRun = _sentThisRun[key];
    if (inRun == version) return null;
    final last = inRun ?? await _load(key);
    final text = topic ?? '';
    _sentThisRun[key] = version;
    if (inRun == null && text.isEmpty && (last == null || last == version)) {
      // Nothing to say: no topic now, and the backend never heard one (or
      // already heard that it was cleared).
      return null;
    }
    if (last != version) await _save(key, version);
    return text;
  }

  /// The prompt block for [topic] (see [take]).
  static String block(String topic) => topic.isEmpty
      ? '[Group topic cleared by the group admins]'
      : '[Group topic: $topic]';
}
