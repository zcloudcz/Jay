import 'dart:async';

import 'history_store.dart';
import 'provider.dart';

/// Where the bridge writes into a chat. The Jay glue implements it on top
/// of the bot runtime; tests implement it with a list.
///
/// WHY an interface instead of `BotMessage` directly: the whole turn logic
/// (history, streaming edits, retries, timeouts) is then testable without
/// a server, a hub or E2E sessions. Same seam as a2a_bridge.
abstract class ChatSink {
  /// Sends [text] as a message that can later be edited (the progress note).
  Future<ProgressHandle> progress(String text);

  /// Sends [text] as a normal reply.
  Future<void> reply(String text);
}

/// A sent progress message.
abstract class ProgressHandle {
  /// Replaces its text (a Jay `edit`).
  Future<void> update(String text);
}

/// Replies are cut into chunks of this many characters (same as the Hermes
/// and A2A bridges): readability, and far below the hub's envelope limit.
const maxReplyChars = 4000;

/// Splits a long reply into chunks of at most [limit] characters, preferring
/// a line break, then a space, so words stay whole.
///
/// WHY a copy of a2a_bridge's function instead of a dependency on that
/// package: twenty lines are cheaper than coupling two bridges (the spec's
/// B2 rule: extract into calltype_bot only what is small and safe).
List<String> splitMessage(String text, {int limit = maxReplyChars}) {
  final chunks = <String>[];
  var rest = text.trim();
  while (rest.length > limit) {
    var cut = rest.lastIndexOf('\n', limit);
    if (cut < limit ~/ 2) cut = rest.lastIndexOf(' ', limit);
    if (cut < limit ~/ 2) cut = limit;
    chunks.add(rest.substring(0, cut).trimRight());
    rest = rest.substring(cut).trimLeft();
  }
  if (rest.isNotEmpty) chunks.add(rest);
  return chunks;
}

/// `/cmd args`, `/cmd@CT-ABCD-EFGH args` -> (cmd, args). Null for normal
/// text. The `@handle` suffix is what the app inserts in groups.
({String command, String args})? parseSlashCommand(String text) {
  final m = RegExp(
    r'^/([A-Za-z0-9_]{1,32})(?:@[A-Za-z0-9-]+)?(?:\s+([\s\S]*))?$',
  ).firstMatch(text.trim());
  if (m == null) return null;
  return (command: m.group(1)!.toLowerCase(), args: (m.group(2) ?? '').trim());
}

/// The bot's "/" menu (published at start).
const botCommands = <({String command, String description})>[
  (command: 'new', description: 'Start a new conversation (forget this chat)'),
  (command: 'help', description: 'What this bot is and how to use it'),
];

/// User-facing texts, in one place.
abstract final class BridgeTexts {
  static const working = 'Working on it...';
  static const reset =
      'New conversation started. I no longer remember the earlier messages '
      'of this chat.';
  static const empty = '(The model sent an empty reply.)';

  /// Bot talk hit the group's limit (same text as hermes_bridge).
  static const botLimit = 'Bot limit reached, waiting for a human.';

  /// The one-time first message to each owner (spec B4), Czech first: the
  /// owner base is Czech, the second line serves everyone else.
  static String greeting(String name) =>
      'Ahoj, jsem $name. Napiš mi.\nHi, I am $name. Write to me.';

  static String help(String name, String provider, int history) =>
      'I am $name, an AI assistant ($provider).\n'
      'Write to me like to a person. In a group, mention me or reply to my '
      'message.\n'
      '/new: start a new conversation (I remember the last $history '
      'messages of each chat until then).\n'
      '/help: this text.';

  static String timeout(Duration d) =>
      'Sorry, the model did not answer within ${d.inSeconds} seconds.';
  static String auth(String detail) =>
      'Sorry, the AI provider refused the credentials ($detail). The bot '
      'owner has to fix the API key or the CLI login and restart the bot.';
  static String failed(String detail) => 'Sorry, I could not answer: $detail';
}

/// The LLM side of the bot: one [handle] call per incoming chat message.
///
/// The runtime runs handlers of ONE conversation one after another, so per
/// conversation there is never more than one turn in flight and the
/// history read at the start of [handle] is still current at its end.
class LlmBridge {
  LlmBridge({
    required this.provider,
    required this.history,
    required this.displayName,
    required this.systemPrompt,
    this.timeout = const Duration(seconds: 300),
    this.progressAfter = const Duration(seconds: 5),
    this.editInterval = const Duration(seconds: 3),
    this.maxProgressEdits = 30,
    Future<void> Function(Duration)? sleep,
    this.log = _noLog,
  }) : _sleep = sleep ?? Future<void>.delayed;

  static void _noLog(String _) {}

  final LlmProvider provider;
  final HistoryStore history;
  final String displayName;
  final String systemPrompt;
  final Duration timeout;

  /// No progress message when the answer is complete within this; zero =
  /// never post one (the typing indicator still runs).
  final Duration progressAfter;

  /// Minimum time between two streaming edits of the progress message.
  final Duration editInterval;

  /// WHY a cap on edits: an old Jay client throws on the unknown `edit`
  /// type and the server keeps those envelopes queued for it until the TTL
  /// (agent-messaging contract, compatibility section). A long streamed
  /// answer must not pile up hundreds of them.
  final int maxProgressEdits;
  final Future<void> Function(Duration) _sleep;
  final void Function(String) log;

  /// Answers [text] from conversation [conversationId] into [sink].
  /// [senderLabel] (a handle or name, `(bot)` for bots) is prefixed in
  /// groups so the model knows who of several members is speaking; the
  /// history of a group is shared by all its members.
  Future<void> handle({
    required String conversationId,
    required String text,
    required ChatSink sink,
    String? senderLabel,
  }) async {
    final message = text.trim();
    if (message.isEmpty) return;

    final slash = parseSlashCommand(message);
    switch (slash?.command) {
      case 'new' || 'reset':
        await history.reset(conversationId);
        await sink.reply(BridgeTexts.reset);
        return;
      case 'help' || 'start':
        // `/start` is what a calltype://bot/<handle>?start= link pre-fills.
        await sink.reply(
          BridgeTexts.help(displayName, provider.label, history.cap),
        );
        return;
    }

    final userTurn = ChatTurn.user(
      senderLabel == null ? message : '[from $senderLabel] $message',
    );
    final conversation = [...await history.history(conversationId), userTurn];
    final run = _Run(this, sink);
    try {
      final answer = await _answer(conversation, run);
      final shown = answer.trim().isEmpty ? BridgeTexts.empty : answer;
      await run.finish(shown);
      if (answer.trim().isNotEmpty) {
        await history.append(conversationId, [
          userTurn,
          ChatTurn.assistant(answer),
        ]);
      }
    } on TimeoutException {
      log('LLM: timeout in conversation $conversationId');
      await run.finish(BridgeTexts.timeout(timeout));
    } on LlmException catch (e) {
      log('LLM: ${provider.label}: $e');
      await run.finish(
        e.isAuth
            ? BridgeTexts.auth('HTTP ${e.status}: ${_short(e.message)}')
            : BridgeTexts.failed(_short(e.message)),
      );
    } finally {
      run.stop();
    }
  }

  /// One provider call, retried once on a 429 that came before any text.
  ///
  /// WHY once: a rate limit right after another message is common on new
  /// API keys (low tier limits) and usually clears within seconds; a
  /// second refusal means the owner's quota really is exhausted.
  Future<String> _answer(List<ChatTurn> conversation, _Run run) async {
    final deadline = DateTime.now().add(timeout);
    try {
      return await _collect(conversation, run, deadline);
    } on LlmException catch (e) {
      if (!e.isRateLimit || run.received) rethrow;
      final wait = e.retryAfter == null
          ? const Duration(seconds: 5)
          : (e.retryAfter! > const Duration(seconds: 30)
                ? const Duration(seconds: 30)
                : e.retryAfter!);
      if (DateTime.now().add(wait).isAfter(deadline)) rethrow;
      log('LLM: rate limited, retrying once in ${wait.inSeconds} s.');
      await _sleep(wait);
      return _collect(conversation, run, deadline);
    }
  }

  Future<String> _collect(
    List<ChatTurn> conversation,
    _Run run,
    DateTime deadline,
  ) {
    final done = Completer<String>();
    final buffer = StringBuffer();
    late final StreamSubscription<String> sub;
    sub = provider
        .reply(conversation, system: systemPrompt)
        .listen(
          (piece) {
            buffer.write(piece);
            run.partial(buffer.toString());
          },
          onError: (Object e, StackTrace st) {
            if (!done.isCompleted) {
              done.completeError(
                e is LlmException || e is TimeoutException
                    ? e
                    : LlmException('$e'),
                st,
              );
            }
          },
          onDone: () {
            if (!done.isCompleted) done.complete(buffer.toString());
          },
          cancelOnError: true,
        );
    final left = deadline.difference(DateTime.now());
    return done.future.timeout(
      left.isNegative ? Duration.zero : left,
      onTimeout: () {
        // Aborts the HTTP request or kills the CLI process.
        unawaited(sub.cancel());
        throw TimeoutException('LLM answer', timeout);
      },
    );
  }

  static String _short(String text) {
    final t = text.trim();
    return t.length <= 300 ? t : '${t.substring(0, 297)}...';
  }
}

/// Per-message progress bookkeeping: the "Working on it..." note and the
/// streaming edits of it.
class _Run {
  _Run(this.bridge, this.sink) {
    if (bridge.progressAfter > Duration.zero) {
      _timer = Timer(bridge.progressAfter, () {
        _start = true;
        _tick();
        _ticker = Timer.periodic(bridge.editInterval, (_) => _tick());
      });
    }
  }

  final LlmBridge bridge;
  final ChatSink sink;
  Timer? _timer;
  Timer? _ticker;
  bool _start = false;
  bool _finished = false;
  String _partial = '';
  String? _shown;
  ProgressHandle? _progress;
  var _edits = 0;

  /// The one in-flight sink operation of the ticker; [finish] waits for it
  /// so the final text can never be overwritten by a late partial edit.
  Future<void> _op = Future.value();

  bool get received => _partial.isNotEmpty;

  void partial(String text) => _partial = text;

  String _progressText() {
    final p = _partial.trim();
    if (p.isEmpty) return BridgeTexts.working;
    // The first chunk only: the rest follows as replies at the end.
    final head = p.length <= maxReplyChars - 4
        ? p
        : p.substring(0, maxReplyChars - 4);
    return '$head ...';
  }

  void _tick() {
    if (_finished || !_start) return;
    _op = _op.then((_) async {
      if (_finished) return;
      final text = _progressText();
      if (text == _shown) return;
      try {
        final existing = _progress;
        if (existing == null) {
          _progress = await sink.progress(text);
        } else {
          if (_edits >= bridge.maxProgressEdits) return;
          _edits++;
          await existing.update(text);
        }
        _shown = text;
      } catch (e) {
        bridge.log('LLM: progress update failed ($e).');
      }
    });
  }

  void stop() {
    _finished = true;
    _timer?.cancel();
    _ticker?.cancel();
  }

  /// The final answer: the progress message becomes its first chunk (so the
  /// chat does not keep a stale "Working on it..."), further chunks follow
  /// as replies.
  Future<void> finish(String text) async {
    stop();
    await _op;
    final chunks = splitMessage(text);
    if (chunks.isEmpty) return;
    var rest = chunks;
    final progress = _progress;
    if (progress != null) {
      try {
        await progress.update(chunks.first);
        rest = chunks.sublist(1);
      } catch (e) {
        // An edit can fail (message gone); the answer must still arrive.
        bridge.log('LLM: progress edit failed ($e); replying instead.');
      }
    }
    for (final chunk in rest) {
      await sink.reply(chunk);
    }
  }
}
