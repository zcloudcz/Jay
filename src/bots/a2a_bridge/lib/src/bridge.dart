import 'dart:async';
import 'dart:io';

import 'a2a_client.dart';
import 'a2a_protocol.dart';
import 'commands.dart';
import 'state_store.dart';

/// Where the bridge writes into a chat. The Jay glue implements it on top
/// of the bot runtime; tests implement it with a list.
///
/// WHY an interface instead of `BotMessage` directly: all A2A behaviour
/// (state machine, polling, progress throttling) is then testable without
/// a server, a hub or E2E sessions.
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
/// bridge): readability, and far below the hub's envelope limit.
const maxReplyChars = 4000;

/// Splits a long reply into chunks of at most [limit] characters, preferring
/// a line break, then a space, so words stay whole.
///
/// WHY a copy of the Hermes bridge's function instead of a dependency on
/// that package: `hermes_bridge` drags in its own bot policy and endpoint
/// code; twenty lines are cheaper than that coupling.
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

/// User-facing texts, in one place.
abstract final class BridgeTexts {
  static const working = 'Working on it...';
  static const reset =
      'New conversation started. The agent no longer sees '
      'the earlier messages of this chat.';
  static const empty = '(The agent sent an empty reply.)';
  static const needsInput = 'The agent needs more information.';
  static const canceled = 'The agent canceled the task.';
  static String timeout(Duration d) =>
      'The agent did not finish within ${d.inSeconds} seconds.';
  static String failed(String reason) =>
      reason.isEmpty ? 'The agent failed.' : 'The agent failed: $reason';
  static String rejected(String reason) =>
      '${reason.isEmpty ? 'The agent rejected the request.' : 'The agent rejected the request: $reason'}'
      '\n(Send /reset to start a new conversation.)';
  static String authRequired(String reason) =>
      'The agent asks for an authorization this bridge cannot provide'
      '${reason.isEmpty ? '.' : ': $reason'}';
  static String auth(int status) =>
      'The agent refused the bridge\'s credentials (HTTP $status). The bot '
      'operator has to check A2A_TOKEN.';
  static const unreachable =
      'The agent is unreachable or answered with an error. Please try again later.';
}

/// The A2A side of the bot: one [handle] call per incoming chat message.
///
/// The runtime runs handlers of ONE conversation one after another, so per
/// conversation there is never more than one A2A exchange in flight; the
/// state read at the start of [handle] is still valid at its end.
class A2aBridge {
  A2aBridge({
    required this.client,
    required this.state,
    required AgentCard card,
    this.timeout = const Duration(seconds: 300),
    this.pollInterval = const Duration(seconds: 3),
    this.maxProgressEdits = 30,
    this.log = _noLog,
  }) {
    final menu = commandsFromSkills(card.skills);
    commands = List.unmodifiable(menu.commands);
    _skills = menu.skills;
  }

  static void _noLog(String _) {}

  final A2aClient client;
  final StateStore state;
  final Duration timeout;
  final Duration pollInterval;

  /// WHY a cap on edits: an old Jay client throws on the unknown `edit`
  /// type and the server keeps those envelopes queued for it until the TTL
  /// (contract, compatibility section). Unbounded progress edits on a long
  /// task would pile up there.
  final int maxProgressEdits;
  final void Function(String) log;

  /// Published as the bot's "/" menu.
  late final List<A2aCommand> commands;
  late final Map<String, A2aSkill> _skills;

  /// Answers [text] from conversation [conversationId] into [sink].
  /// [senderLabel] (a handle) is prefixed in groups so the agent knows who
  /// of several people is speaking.
  ///
  /// Returns true when the turn ended in an error text (timeout, agent
  /// unreachable, a failed/rejected/canceled/auth-required task) instead of
  /// an answer: the runtime then ends with ❌ instead of ✅ (spec
  /// 2026-11-11-bot-ack-reactions).
  Future<bool> handle({
    required String conversationId,
    required String text,
    required ChatSink sink,
    String? senderLabel,
  }) async {
    var outgoing = text.trim();
    if (outgoing.isEmpty) return false;

    final slash = parseSlashCommand(outgoing);
    if (slash != null && slash.command == resetCommand) {
      await state.reset(conversationId);
      await sink.reply(BridgeTexts.reset);
      return false;
    }
    final skill = slash == null ? null : _skills[slash.command];
    if (skill != null) {
      // A2A has no "invoke skill X" field in a message; a readable prefix is
      // what every LLM-backed agent understands.
      outgoing = slash!.args.isEmpty
          ? '[Skill: ${skill.id}]'
          : '[Skill: ${skill.id}] ${slash.args}';
    }
    if (senderLabel != null) outgoing = '[from $senderLabel] $outgoing';

    final deadline = DateTime.now().add(timeout);
    final run = _Run(this, sink);
    try {
      return await _exchange(conversationId, outgoing, deadline, run);
    } on TimeoutException {
      log('A2A: timeout in conversation $conversationId');
      await run.deliver(BridgeTexts.timeout(timeout));
    } on A2aException catch (e) {
      log('A2A: $e');
      await run.deliver(
        e.isAuth ? BridgeTexts.auth(e.httpStatus!) : BridgeTexts.unreachable,
      );
    } on IOException catch (e) {
      log('A2A: $e');
      await run.deliver(BridgeTexts.unreachable);
    }
    return true;
  }

  Duration _remaining(DateTime deadline) {
    final left = deadline.difference(DateTime.now());
    if (left <= Duration.zero) throw TimeoutException(null, timeout);
    return left;
  }

  /// True = the turn failed (see [handle]).
  Future<bool> _exchange(
    String conversationId,
    String text,
    DateTime deadline,
    _Run run,
  ) async {
    final before = state.get(conversationId);
    A2aResult result;
    try {
      result = await client.sendMessage(
        text,
        contextId: before.contextId,
        taskId: before.taskId,
        timeout: _remaining(deadline),
      );
    } on A2aException catch (e) {
      // WHY retry without the task: the remembered input-required task may
      // have expired or been finished on the agent side (restart, timeout),
      // and the agent then refuses the taskId (TaskNotFound, terminal task).
      // The user's message is still meant for the conversation, so send it
      // once more as a new task in the same context.
      if (before.taskId == null || e.rpcCode == null) rethrow;
      log('A2A: task ${before.taskId} refused ($e); sending as a new task.');
      await state.set(
        conversationId,
        ConversationState(contextId: before.contextId),
      );
      result = await client.sendMessage(
        text,
        contextId: before.contextId,
        timeout: _remaining(deadline),
      );
    }

    final contextId = result.contextId ?? before.contextId;
    switch (result) {
      case A2aMessage():
        // A direct message closes nothing and opens nothing: no task to keep.
        await state.set(
          conversationId,
          ConversationState(contextId: contextId),
        );
        await run.deliver(
          result.text.isEmpty ? BridgeTexts.empty : result.text,
        );
        return false;
      case A2aTask():
        var task = result;
        while (!task.state.isSettled) {
          await run.showProgress(task.statusText);
          await Future<void>.delayed(_min(pollInterval, _remaining(deadline)));
          task = await _poll(task.id, deadline);
        }
        return _settle(conversationId, task, task.contextId ?? contextId, run);
    }
  }

  static Duration _min(Duration a, Duration b) => a < b ? a : b;

  /// One GetTask, retried on transient errors until [deadline].
  ///
  /// WHY only transient errors are swallowed: a 5xx or a dropped connection
  /// during a long task says nothing about the task itself; an auth or
  /// protocol error will not heal by asking again.
  Future<A2aTask> _poll(String taskId, DateTime deadline) async {
    while (true) {
      final left = _remaining(deadline);
      try {
        final cap = const Duration(seconds: 30);
        return await client.getTask(taskId, timeout: left < cap ? left : cap);
      } on A2aException catch (e) {
        if (!e.isTransient) rethrow;
        log('A2A: GetTask $taskId: $e (retrying)');
      } on IOException catch (e) {
        log('A2A: GetTask $taskId: $e (retrying)');
      } on TimeoutException {
        log('A2A: GetTask $taskId timed out (retrying)');
      }
      await Future<void>.delayed(_min(pollInterval, _remaining(deadline)));
    }
  }

  /// Delivers the task's outcome; true when it is an error (see [handle]).
  Future<bool> _settle(
    String conversationId,
    A2aTask task,
    String? contextId,
    _Run run,
  ) async {
    final text = task.text;
    // Only input-required keeps the task: the next message answers it.
    // auth-required is also "interrupted", but the bridge cannot complete
    // an auth flow, so the user's next message starts a new task instead.
    final keepTask =
        task.state == TaskState.inputRequired && task.id.isNotEmpty;
    await state.set(
      conversationId,
      ConversationState(
        contextId: contextId,
        taskId: keepTask ? task.id : null,
      ),
    );
    final reason = _short(text);
    final answer = switch (task.state) {
      TaskState.completed => text.isEmpty ? BridgeTexts.empty : text,
      TaskState.inputRequired => text.isEmpty ? BridgeTexts.needsInput : text,
      TaskState.authRequired => BridgeTexts.authRequired(reason),
      TaskState.failed => BridgeTexts.failed(reason),
      TaskState.rejected => BridgeTexts.rejected(reason),
      TaskState.canceled => BridgeTexts.canceled,
      _ => text.isEmpty ? BridgeTexts.empty : text,
    };
    await run.deliver(answer);
    return const {
      TaskState.authRequired,
      TaskState.failed,
      TaskState.rejected,
      TaskState.canceled,
    }.contains(task.state);
  }

  /// Error reasons come from the agent and may be long stack traces; the
  /// chat gets a readable excerpt (the full text is the agent's to log).
  static String _short(String text) {
    final t = text.trim();
    return t.length <= 500 ? t : '${t.substring(0, 497)}...';
  }
}

/// Per-message progress bookkeeping.
class _Run {
  _Run(this.bridge, this.sink);

  final A2aBridge bridge;
  final ChatSink sink;
  ProgressHandle? _progress;
  String? _shown;
  var _edits = 0;

  static String _progressText(String status) {
    final s = status.trim();
    if (s.isEmpty) return BridgeTexts.working;
    final short = s.length <= 300 ? s : '${s.substring(0, 297)}...';
    return '${BridgeTexts.working}\n$short';
  }

  /// Posts the progress message once, then edits it only when the agent's
  /// status text CHANGES (not on every poll) and at most
  /// [A2aBridge.maxProgressEdits] times.
  Future<void> showProgress(String status) async {
    final text = _progressText(status);
    if (text == _shown) return;
    final existing = _progress;
    if (existing == null) {
      _progress = await sink.progress(text);
    } else {
      if (_edits >= bridge.maxProgressEdits) return;
      _edits++;
      await existing.update(text);
    }
    _shown = text;
  }

  /// The final answer: the progress message becomes its first chunk (so the
  /// chat does not keep a stale "Working on it..."), further chunks follow
  /// as replies.
  Future<void> deliver(String text) async {
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
        bridge.log('A2A: progress edit failed ($e); replying instead.');
      }
    }
    for (final chunk in rest) {
      await sink.reply(chunk);
    }
  }
}
