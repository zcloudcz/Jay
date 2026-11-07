import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:calltype_bot/calltype_bot.dart';

import 'src/bot_talk.dart';
import 'src/hermes_events.dart';
import 'src/progress.dart';
import 'src/reply_directive.dart';
import 'src/send_endpoint.dart';

export 'src/bot_talk.dart';
export 'src/hermes_events.dart';
export 'src/progress.dart';
export 'src/reply_directive.dart';
export 'src/send_endpoint.dart';

/// Answers one user message within a conversation in one go. Kept for
/// backends without streaming (and simple fakes): the bridge wraps it into a
/// [StreamingBackend] that yields only the final answer.
typedef Backend =
    Future<String> Function(String text, {required String conversationId});

/// Runs one turn and reports it as it happens (tools, approvals, answer).
/// [HermesClient.chat] in production; tests feed scripted events.
typedef StreamingBackend =
    Stream<HermesEvent> Function(String text, {required String conversationId});

/// Answers a pending approval: [choice] is `once`, `session` or `deny`.
typedef ApprovalBackend =
    Future<void> Function(String runId, String requestId, String choice);

/// Replies are cut into chunks of this many characters. The hub's hard limit
/// is far higher (768 KiB of base64 per envelope); this is about chat
/// readability and keeping every chunk comfortably below that limit.
const maxReplyChars = 4000;

/// HTTP client for the Hermes Agent API server
/// (`gateway/platforms/api_server.py` in NousResearch/hermes-agent).
///
/// Uses Hermes' session resource API so HERMES keeps the per-conversation
/// memory and the bridge stays stateless:
/// ```
/// POST /api/sessions                  {"id": SESSION}    -> 201 | 409
/// POST /api/sessions/SESSION/chat     {"message": TEXT}
///      -> {"message": {"role": "assistant", "content": REPLY}, …}
/// ```
/// Auth is `Authorization: Bearer <API_SERVER_KEY>`. See README for what was
/// read in their source versus assumed.
class HermesClient {
  HermesClient({
    required String baseUrl,
    required this.apiKey,
    this.timeout = const Duration(minutes: 5),
    this.retryDelay = const Duration(seconds: 2),
    this.stream = true,
    void Function(String line)? log,
  }) : _base = Uri.parse(baseUrl.endsWith('/') ? baseUrl : '$baseUrl/'),
       _log = log ?? ((_) {});

  /// Use the SSE route (env `HERMES_STREAM`, default true).
  final bool stream;
  final void Function(String) _log;

  /// Set once the server proved it has no streaming route (an older Hermes):
  /// from then on every turn goes to `/chat` directly.
  bool _streamUnsupported = false;

  final Uri _base;
  final String apiKey;

  /// Generous by default: one Hermes turn may run tools for minutes.
  final Duration timeout;
  final Duration retryDelay;
  final _http = HttpClient();

  /// The single place that knows Hermes' URL and JSON shape.
  Future<String> ask(String text, {required String conversationId}) async {
    // One Hermes session per CallType conversation. The prefix keeps our
    // sessions recognisable in Hermes' own session list.
    final session = 'calltype-$conversationId';
    final chat = 'api/sessions/$session/chat';
    var response = await _post(chat, {'message': text});
    if (response.status == 404) {
      // First message of this conversation: create the session, then chat.
      // 409 = it already exists (a parallel create won) — equally fine.
      final created = await _post('api/sessions', {'id': session});
      if (created.status != 201 && created.status != 409) {
        throw HttpException('Hermes session create: HTTP ${created.status}');
      }
      response = await _post(chat, {'message': text});
    }
    if (response.status != 200) {
      throw HttpException('Hermes chat: HTTP ${response.status}');
    }
    final content = (response.json?['message'] as Map?)?['content'];
    if (content is! String || content.trim().isEmpty) {
      throw const FormatException('Hermes returned no assistant text.');
    }
    return content;
  }

  /// One turn as events: `POST /api/sessions/SESSION/chat/stream` (SSE).
  ///
  /// A 404 means either "unknown session" or "no such route" (an older
  /// Hermes). The session is created and the stream tried once more; a
  /// second 404 can then only mean the route is missing, and the turn (and
  /// every later one) falls back to [ask]. While streaming, [timeout] is the
  /// longest SILENCE allowed: Hermes sends keepalive comments, so a long
  /// tool run is fine, a dead connection is not.
  Stream<HermesEvent> chat(
    String text, {
    required String conversationId,
  }) async* {
    if (!stream || _streamUnsupported) {
      yield HermesCompleted(await ask(text, conversationId: conversationId));
      return;
    }
    final session = 'calltype-$conversationId';
    final path = 'api/sessions/$session/chat/stream';
    final body = {'message': text};
    var response = await _openStream(path, body);
    if (response.statusCode == 404) {
      await response.drain<void>();
      final created = await _post('api/sessions', {'id': session});
      if (created.status != 201 && created.status != 409) {
        throw HttpException('Hermes session create: HTTP ${created.status}');
      }
      response = await _openStream(path, body);
    }
    if (response.statusCode == 404 || response.statusCode == 405) {
      await response.drain<void>();
      _streamUnsupported = true;
      _log('Hermes has no streaming chat route: using /chat from now on.');
      yield HermesCompleted(await ask(text, conversationId: conversationId));
      return;
    }
    if (response.statusCode != 200) {
      await response.drain<void>();
      throw HttpException('Hermes chat stream: HTTP ${response.statusCode}');
    }
    yield* _readSse(response);
  }

  /// Parses SSE frames (`event:` + `data:` lines, blank line = end of frame,
  /// `:` lines = keepalive comments) until `done`.
  Stream<HermesEvent> _readSse(HttpClientResponse response) async* {
    String? name;
    final data = StringBuffer();
    final lines = response
        .timeout(timeout)
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (line.isEmpty) {
        final event = name ?? 'message';
        final raw = data.toString();
        name = null;
        data.clear();
        if (event == 'done') return;
        if (raw.isEmpty) continue;
        Object? decoded;
        try {
          decoded = jsonDecode(raw);
        } on FormatException {
          continue; // one unreadable frame must not end the turn
        }
        final parsed = hermesEventFromSse(event, decoded);
        if (parsed != null) yield parsed;
      } else if (line.startsWith(':')) {
        continue;
      } else if (line.startsWith('event:')) {
        name = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        if (data.isNotEmpty) data.write('\n');
        data.write(line.substring(5).trimLeft());
      }
    }
  }

  /// `POST /v1/runs/RUN/approval {"choice", "request_id"}` (Hermes
  /// `api_server_runs.py`, `_handle_run_approval`). Not retried: a lost
  /// answer is visible (the turn keeps waiting) and the owner can press again.
  Future<void> approve(String runId, String requestId, String choice) async {
    final result = await _postOnce('v1/runs/$runId/approval', {
      'choice': choice,
      'request_id': requestId,
    }).timeout(const Duration(seconds: 30));
    if (result.status != 200) {
      final error = result.json?['error'];
      throw HttpException(
        'Hermes approval: HTTP ${result.status}'
        '${error is Map && error['code'] is String ? ' ${error['code']}' : ''}',
      );
    }
  }

  /// Opens the SSE request with the same retry rule as [_post]. Retrying is
  /// safe here: nothing ran until the server answered with its headers.
  Future<HttpClientResponse> _openStream(
    String path,
    Map<String, dynamic> body,
  ) async {
    for (var attempt = 1; ; attempt++) {
      try {
        final request = await _http.postUrl(_base.resolve(path));
        request.headers.contentType = ContentType.json;
        request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
        if (apiKey.isNotEmpty) {
          request.headers.set(
            HttpHeaders.authorizationHeader,
            'Bearer $apiKey',
          );
        }
        request.add(utf8.encode(jsonEncode(body)));
        final response = await request.close().timeout(timeout);
        final transient =
            response.statusCode >= 500 || response.statusCode == 429;
        if (!transient || attempt == 2) return response;
        await response.drain<void>();
      } on TimeoutException {
        rethrow;
      } on IOException {
        if (attempt == 2) rethrow;
      }
      await Future<void>.delayed(retryDelay);
    }
  }

  /// POST with ONE retry on connection errors and 5xx/429.
  ///
  /// WHY a timeout is NOT retried: a timed-out agent turn may still be
  /// running tools on the Hermes side; sending the instruction again would
  /// execute it twice. The user gets the apology and decides.
  Future<({int status, Map<String, dynamic>? json})> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    for (var attempt = 1; ; attempt++) {
      try {
        final result = await _postOnce(path, body).timeout(timeout);
        final transient = result.status >= 500 || result.status == 429;
        if (!transient || attempt == 2) return result;
      } on TimeoutException {
        rethrow;
      } on IOException {
        if (attempt == 2) rethrow;
      }
      await Future<void>.delayed(retryDelay);
    }
  }

  Future<({int status, Map<String, dynamic>? json})> _postOnce(
    String path,
    Map<String, dynamic> body,
  ) async {
    final request = await _http.postUrl(_base.resolve(path));
    request.headers.contentType = ContentType.json;
    if (apiKey.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    }
    request.add(utf8.encode(jsonEncode(body)));
    final response = await request.close();
    final text = await utf8.decodeStream(response);
    Map<String, dynamic>? json;
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) json = decoded;
    } on FormatException {
      // Non-JSON error page from a proxy: the status code is all we need.
    }
    return (status: response.statusCode, json: json);
  }

  void close() => _http.close(force: true);
}

/// `ALLOWED_HANDLES` -> normalised set. Handles are upper-case server-side.
Set<String> parseAllowedHandles(String? raw) => {
  for (final handle in (raw ?? '').split(','))
    if (handle.trim().isNotEmpty) handle.trim().toUpperCase(),
};

/// Splits a long reply into chunks of at most [limit] characters, preferring
/// to cut at a line break, then at a space, so words stay whole.
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

/// `BOT_COMMANDS` (`cmd:description;cmd2:description`) -> commands for
/// [CallTypeBot.setCommands]. A leading `/` is tolerated. Throws
/// [FormatException] naming the bad entry: a typo in the operator's config
/// should stop the start, not silently publish half a menu.
List<BotCommand> parseBotCommands(String? raw) {
  final commands = <BotCommand>[];
  final seen = <String>{};
  for (final entry in (raw ?? '').split(';')) {
    if (entry.trim().isEmpty) continue;
    final colon = entry.indexOf(':');
    if (colon < 0) {
      throw FormatException('BOT_COMMANDS entry without ":": "$entry"');
    }
    var command = entry.substring(0, colon).trim();
    if (command.startsWith('/')) command = command.substring(1);
    final parsed = BotCommand(
      command: command,
      description: entry.substring(colon + 1).trim(),
    );
    if (!parsed.isValid) {
      throw FormatException(
        'BOT_COMMANDS entry "$entry": command must be [a-z0-9_]{1,32}, '
        'description 1..100 characters',
      );
    }
    if (!seen.add(command)) {
      throw FormatException('BOT_COMMANDS lists /$command twice');
    }
    commands.add(parsed);
  }
  return commands;
}

/// What the bridge does with an owner's emoji reaction (env `REACTION_MODE`,
/// spec docs/superpowers/specs/2026-11-07-message-reactions.md).
enum ReactionMode {
  /// One Hermes turn per reaction; its answer is NOT posted (default).
  silent,

  /// No turn: kept in memory and put in front of the owner's next message.
  batch,

  /// A normal turn whose answer is posted into the chat.
  reply,

  /// Ignored.
  off,
}

/// `REACTION_MODE` -> [ReactionMode]; empty = [ReactionMode.silent]. Throws
/// [FormatException] for anything else, so a typo stops the start.
ReactionMode parseReactionMode(String? raw) {
  final value = (raw ?? '').trim().toLowerCase();
  if (value.isEmpty) return ReactionMode.silent;
  for (final mode in ReactionMode.values) {
    if (mode.name == value) return mode;
  }
  throw FormatException(
    'REACTION_MODE must be one of '
    '${ReactionMode.values.map((m) => m.name).join(', ')}, got "$raw"',
  );
}

/// What the agent reads for one reaction, e.g.
/// `[reaction 👍 to your message: "Deployed to beta."]`.
String reactionNote(BotReaction reaction) {
  final text = reaction.targetText;
  if (!reaction.targetIsOwn || text == null || text.trim().isEmpty) {
    return '[reaction ${reaction.emoji} to a message]';
  }
  return '[reaction ${reaction.emoji} to your message: "$text"]';
}

/// Most reactions kept per conversation in [ReactionMode.batch].
const maxBatchedReactions = 20;

/// Appended to a [ReactionMode.silent] turn, so the agent does not write a
/// reply nobody will read.
const silentReactionHint =
    '(Feedback only. Your answer to this is not shown to the user; no reply '
    'is needed.)';

/// Told to the agent once per conversation (per bridge run), in front of an
/// owner's message: the reply directive, see [parseReplyDirective].
const reactDirectiveHint =
    '(You may start your reply with a line [react:EMOJI] to react to this '
    'message with one emoji; a reply of only that line sends no text.)';

/// What a progress message becomes when the answer was only a reaction
/// directive: the bot cannot delete it, and "Working on it..." would stay.
const reactedProgressText = 'Done.';

/// The one notice a bot posts when a bot-only exchange hits its limit.
const botLimitNotice = 'Bot limit reached, waiting for a human.';

/// Answer to an approval button pressed by someone who is not an owner.
const approvalOwnerOnlyNotice = 'Only the bot owner can approve.';

/// An answer that is exactly this (trimmed, any case) sends nothing. The
/// agent's way to end a bot exchange without feeding it one more message.
const silentReply = '[SILENT]';

/// Appended to every bot message the agent sees, so it knows how to stay
/// quiet. WHY in the prompt: each bridge's agent learns it without any
/// per-agent setup.
const botSilenceHint =
    '\n[This message is from a bot. Answer $silentReply to send nothing.]';

/// True when [text] means "send nothing".
bool isSilentReply(String text) => text.trim().toUpperCase() == silentReply;

/// Same text the runtime uses for a failed handler.
const _apology = 'Sorry, something went wrong. Please try again.';

/// Buttons of an approval request, in this order; filtered by what Hermes
/// offers for the request. `always` is never offered: a permanent allowlist
/// entry is an operator decision, not a chat button.
const _approvalChoices = {
  'once': 'Approve once',
  'session': 'Approve for session',
  'deny': 'Deny',
};

/// One approval request the bridge posted and still waits for.
class _PendingApproval {
  _PendingApproval(
    this.runId,
    this.requestId,
    this.conversationId,
    this.text,
    this.message,
  );
  final String runId;
  final String requestId;
  final String conversationId;
  final String text;
  final BotSentMessage message;
}

/// The running bridge: the message handler and the local send path share its
/// [policy], so a message started via /send counts as a bot turn too.
class HermesBridge {
  HermesBridge._(
    this.bot,
    this.policy,
    this._allowedIds,
    this._allowedHandles,
    this._backend,
    this._approve,
    this._progress,
    this._log,
    this._reactionMode,
  );

  final CallTypeBot bot;
  final BotTalkPolicy policy;

  /// Owner device id (lower-case) -> handle.
  final Map<String, String> _allowedIds;
  final Set<String> _allowedHandles;
  final StreamingBackend _backend;
  final ApprovalBackend? _approve;
  final ProgressSettings _progress;
  final void Function(String) _log;
  final ReactionMode _reactionMode;

  /// [ReactionMode.batch]: notes per conversation, oldest first, until the
  /// owner's next message takes them along.
  final _pendingReactions = <String, List<String>>{};

  /// Conversations whose agent already got [reactDirectiveHint] in this run.
  final _hinted = <String>{};

  /// Id of the last message received per owner handle (1:1) or group id
  /// (lower-case): the default target of [reactFromLocal]. In memory only.
  final _lastReceived = <String, String>{};

  /// Approval requests still waiting, by token (see [_approvalButtonId]).
  final _approvals = <String, _PendingApproval>{};
  static final _random = Random.secure();

  static final _handlePattern = RegExp(r'^CT-[A-Z0-9]{4}-[A-Z0-9]{4}$');

  String? _owner(String id) => _allowedIds[id.toLowerCase()];

  /// Cheap pre-decrypt check: the owners only. Bots get their second chance
  /// in [_admitGroupBot].
  bool _allowSender(String id) => _owner(id) != null;

  /// Pre-decrypt second chance for a sender that is not an owner, when the
  /// server routes the message to a group.
  ///
  /// WHY rules (a)+(b) already here, and the trade-off: the bot cannot know
  /// beforehand which bots it will meet (a group owner may enable bot talk or
  /// add a bot at any time), so a static list of bot ids would either miss
  /// new peers or admit too many. Checking the group setting costs one REST
  /// lookup per group (cached, dropped on the server's group hint), and only
  /// for senders that are not owners. A stranger can make the bot do that
  /// lookup for a group id it claims; the server answers 403 for a group the
  /// bot is not in, the answer is not cached, so this is bounded by the hub's
  /// delivery rate. The counting rules (c)+(d) need the authenticated group
  /// id and run after decryption in [_handle].
  Future<bool> _admitGroupBot(String id, String groupId) async =>
      policy.eligible(await bot.group(groupId), id) == null;

  Future<void> _handle(BotMessage message) async {
    final human = _owner(message.senderId);
    final groupId = message.groupId;
    if (groupId != null) {
      _lastReceived[groupId.toLowerCase()] = message.id;
    } else if (human != null) {
      _lastReceived[human] = message.id;
    }
    String label;
    if (human != null) {
      // In groups the runtime only calls this handler for messages that
      // address the bot (a mention or a reply to it), so only such a human
      // message re-arms.
      if (groupId != null) policy.humanSpoke(groupId);
      label = '[from $human]';
      if (_hinted.add(message.conversationId.toLowerCase())) {
        label = '$reactDirectiveHint\n$label';
      }
    } else {
      // WHY groups only: a 1:1 bot-to-bot chat has no human watching it.
      if (groupId == null) return;
      final GroupInfo group;
      try {
        group = await bot.group(groupId);
      } catch (e) {
        _log('Group $groupId unreadable, bot message dropped: $e');
        return;
      }
      switch (policy.checkIncoming(group, message.senderId)) {
        case PeerVerdict.drop:
          return;
        case PeerVerdict.notify:
          // WHY not message.reply: a group reply quotes the bot it answers,
          // and a quote addresses that bot (contract section 5), so the
          // other bot would count the notice as one more bot turn and post
          // its own notice. Unquoted, the notice addresses nobody.
          await bot.send(to: groupId, text: botLimitNotice);
          return;
        case PeerVerdict.allow:
          break;
      }
      final peer = group.member(message.senderId);
      label =
          '[from ${peer?.handle ?? peer?.displayName ?? message.senderId} (bot)]';
    }
    // The prefix tells the agent who is speaking (and that it is a bot).
    // Batched reactions of this conversation ride along, oldest first.
    final batched = _pendingReactions.remove(message.conversationId);
    final fromBot = human == null;
    await _runTurn(
      message,
      [
        ...?batched,
        '$label: ${_withContext(message)}${fromBot ? botSilenceHint : ''}',
      ].join('\n'),
      fromBot: fromBot,
    );
  }

  /// An emoji reaction (runtime: in the conversation's queue, after a turn
  /// in progress). Only owners' reactions reach Hermes: a peer bot's would
  /// feed bot-to-bot loops, and removals carry no feedback.
  Future<void> _onReaction(BotReaction reaction) async {
    final human = _owner(reaction.senderId);
    if (human == null || reaction.removed) return;
    final line = '[from $human] ${reactionNote(reaction)}';
    switch (_reactionMode) {
      case ReactionMode.off:
        return;
      case ReactionMode.batch:
        final list = _pendingReactions.putIfAbsent(
          reaction.conversationId,
          () => [],
        );
        list.add(line);
        if (list.length > maxBatchedReactions) list.removeAt(0);
      case ReactionMode.silent:
        await _quietTurn('$line\n$silentReactionHint', reaction.conversationId);
        _log('Reaction ${reaction.emoji} from $human passed to Hermes.');
      case ReactionMode.reply:
        // There is no message being answered here, so a directive is only
        // stripped: it must not reach the chat as text.
        final directive = parseReplyDirective(
          await _quietTurn(line, reaction.conversationId),
        );
        if (directive.emoji != null || directive.invalid) {
          _log('Reply directive in a reaction turn ignored.');
        }
        final answer = directive.text;
        if (answer.trim().isEmpty) return;
        // A 1:1 is addressed by the owner's handle, a group by its id.
        final to = reaction.groupId ?? human;
        for (final chunk in splitMessage(answer)) {
          await bot.send(to: to, text: chunk);
        }
    }
  }

  /// A turn without progress messages or approval buttons: nobody waits for
  /// it in the chat. An approval Hermes asks for here is DENIED (a reaction
  /// must never end up running a command). Returns the answer text.
  Future<String> _quietTurn(String prompt, String conversationId) async {
    final answer = StringBuffer();
    String? completed;
    await for (final event in _backend(
      prompt,
      conversationId: conversationId,
    )) {
      switch (event) {
        case HermesDelta(:final text):
          answer.write(text);
        case HermesToolEvent():
          break;
        case HermesApprovalRequest(:final runId, :final requestId):
          _log('Approval requested in a reaction turn: denied.');
          try {
            await _approve?.call(runId, requestId, 'deny');
          } catch (e) {
            _log('Could not deny approval $runId/$requestId: $e');
          }
        case HermesCompleted(:final content):
          completed = content;
        case HermesError(message: final error):
          throw HermesTurnException(error);
      }
    }
    return completed != null && completed.trim().isNotEmpty
        ? completed
        : answer.toString();
  }

  /// What the agent sees besides the text: the quoted message (people reply
  /// to something specific; without it "yes, do that" is meaningless) or the
  /// fact that a button was pressed.
  static String _withContext(BotMessage message) {
    if (message.action != null) return '[Button: ${message.text}]';
    final quote = message.replyTo;
    if (quote == null || quote.preview.trim().isEmpty) return message.text;
    return '[Replying to: "${quote.preview}"]\n${message.text}';
  }

  /// One backend turn: progress message after a while, approvals as
  /// buttons, the final answer replacing the progress message.
  ///
  /// [fromBot]: the turn answers another bot. WHY no progress message then:
  /// it is a group reply that quotes the other bot, the quote addresses that
  /// bot, and it answers the "Working on it..." as one more message. WHY an
  /// empty answer is silence then: an apology would feed the exchange too.
  Future<void> _runTurn(
    BotMessage message,
    String prompt, {
    bool fromBot = false,
  }) async {
    final progress = ProgressReporter(
      settings: fromBot ? ProgressSettings.never : _progress,
      post: message.reply,
      log: _log,
    )..start();
    final issued = <String>[];
    try {
      final answer = StringBuffer();
      String? completed;
      await for (final event in _backend(
        prompt,
        conversationId: message.conversationId,
      )) {
        switch (event) {
          case HermesDelta(:final text):
            answer.write(text);
          case HermesToolEvent():
            progress.tool(event);
          case HermesApprovalRequest():
            issued.add(await _requestApproval(message, event));
          case HermesCompleted(:final content):
            completed = content;
          case HermesError(message: final error):
            throw HermesTurnException(error);
        }
      }
      // The final event is authoritative; the deltas are only a fallback
      // for a stream that ended without one.
      final text = completed != null && completed.trim().isNotEmpty
          ? completed
          : answer.toString();
      if (isSilentReply(text) || (fromBot && text.trim().isEmpty)) {
        // A progress message already on screen cannot be taken back; it is
        // closed with a neutral mark instead of an answer.
        await progress.finish('-');
        _log('Turn for message ${message.id}: silent, nothing sent.');
        return;
      }
      if (text.trim().isEmpty) {
        throw const FormatException('Hermes returned no assistant text.');
      }
      final directive = parseReplyDirective(text);
      final emoji = directive.emoji;
      if (directive.invalid) {
        _log('Invalid reply directive for message ${message.id}: stripped.');
      }
      if (emoji != null) {
        try {
          await message.react(emoji);
        } catch (e) {
          // The text (if any) still goes out; a lost reaction is cosmetic.
          _log('Reaction to message ${message.id} failed: $e');
        }
      }
      if (directive.text.trim().isEmpty) {
        // A stripped invalid directive and nothing else: no answer at all.
        if (emoji == null) {
          throw const FormatException('Hermes returned no assistant text.');
        }
        // Reaction only: no text message; a progress message on screen
        // cannot be deleted by a bot, so it says the turn is over.
        await progress.finish(reactedProgressText);
        return;
      }
      final chunks = splitMessage(directive.text);
      final replaced = await progress.finish(chunks.first);
      for (final chunk in replaced ? chunks.skip(1) : chunks) {
        await message.reply(chunk);
      }
    } catch (e) {
      // With a progress message on screen the apology replaces it; without
      // one the runtime sends its usual apology.
      if (await progress.finish(_apology)) {
        _log('Turn failed for message ${message.id}: $e');
        return;
      }
      rethrow;
    } finally {
      progress.cancel();
      await _expire(issued);
    }
  }

  /// Posts the approval request with its buttons and remembers it.
  Future<String> _requestApproval(
    BotMessage message,
    HermesApprovalRequest request,
  ) async {
    // A short local token instead of the Hermes ids in the button: run and
    // request ids are 36 + 32 characters, over the 64-character button id
    // limit. It also means only requests THIS bridge issued can be answered.
    final token = [
      for (var i = 0; i < 6; i++)
        _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
    final command = request.command.length > 500
        ? '${request.command.substring(0, 497)}...'
        : request.command;
    final text = [
      'Hermes asks for approval to run:',
      command,
      if (request.description.trim().isNotEmpty)
        '(${request.description.trim()})',
    ].join('\n');
    final offered = request.choices.isEmpty
        ? _approvalChoices.keys
        : _approvalChoices.keys.where(request.choices.contains);
    final sent = await message.reply(
      text,
      actions: [
        for (final choice in offered)
          MessageButton(
            id: _approvalButtonId(token, choice),
            label: _approvalChoices[choice]!,
          ),
      ],
    );
    _approvals[token] = _PendingApproval(
      request.runId,
      request.requestId,
      message.conversationId,
      text,
      sent,
    );
    return token;
  }

  static String _approvalButtonId(String token, String choice) =>
      'approve:$token:$choice';

  /// Approvals still open when their turn ended: Hermes no longer waits for
  /// them, so their buttons go away.
  Future<void> _expire(List<String> tokens) async {
    for (final token in tokens) {
      final pending = _approvals.remove(token);
      if (pending == null) continue;
      try {
        await pending.message.edit(
          '${pending.text}\n\nNo longer pending.',
          actions: const [],
        );
      } catch (e) {
        _log('Could not close approval $token: $e');
      }
    }
  }

  /// A press on one of this bot's button messages. Runs OUTSIDE the
  /// conversation queue (the turn that asked is blocked on this answer).
  Future<void> _onAction(BotMessage press) async {
    final parts = press.action!.id.split(':');
    if (parts.length != 3 || parts[0] != 'approve') {
      // Not an approval: an ordinary button of ours, handled like a message.
      return _handle(press);
    }
    final human = _owner(press.senderId);
    if (human == null) {
      // WHY reply instead of silence: a group member who pressed sees why
      // nothing happened. Allowlisted owners are the only humans that can
      // reach the bot at all; this mostly answers admitted peer bots.
      await press.reply(approvalOwnerOnlyNotice);
      return;
    }
    final (token, choice) = (parts[1], parts[2]);
    final pending = _approvals[token];
    if (pending == null ||
        pending.conversationId != press.conversationId ||
        !_approvalChoices.containsKey(choice) ||
        _approve == null) {
      await press.reply('This approval is no longer pending.');
      return;
    }
    // Claimed before the network call, so a double tap posts only once.
    _approvals.remove(token);
    String outcome;
    try {
      await _approve(pending.runId, pending.requestId, choice);
      outcome = switch (choice) {
        'once' => 'Approved once by $human.',
        'session' => 'Approved for this session by $human.',
        _ => 'Denied by $human.',
      };
    } catch (e) {
      _log('Approval ${pending.runId}/${pending.requestId} failed: $e');
      outcome = 'Could not answer: the request is no longer pending.';
    }
    await pending.message.edit(
      '${pending.text}\n\n$outcome',
      actions: const [],
    );
  }

  /// The /send path: [to] is an owner's handle (1:1), a group id the bot is
  /// in, or `channel:<CH-handle or channel id>`. A group post is a bot turn:
  /// refused (403) once the exchange limit or the pause says so. Long text
  /// goes out in [splitMessage] chunks; the chunks of one request are ONE
  /// turn. A channel post is not, see [_sendToChannel].
  Future<SendOutcome> sendFromLocal(String to, String text) async {
    final target = to.trim();
    if (target.toLowerCase().startsWith(channelTargetPrefix)) {
      return _sendToChannel(
        target.substring(channelTargetPrefix.length).trim(),
        text,
      );
    }
    final handle = target.toUpperCase();
    if (_handlePattern.hasMatch(handle)) {
      // WHY owners only: the endpoint must not turn the bot into a way to
      // message arbitrary people (or other bots 1:1, which nobody watches).
      if (!_allowedHandles.contains(handle) ||
          !_allowedIds.containsValue(handle)) {
        return SendOutcome.forbidden;
      }
    } else {
      final GroupInfo group;
      try {
        group = await bot.group(target);
      } catch (_) {
        return SendOutcome
            .forbidden; // unknown group or not a member: fail closed
      }
      if (!group.isMember(bot.deviceId) ||
          policy.checkOwnSend(group) != PeerVerdict.allow) {
        return SendOutcome.forbidden;
      }
    }
    try {
      for (final chunk in splitMessage(text)) {
        await bot.send(to: target, text: chunk);
      }
      return SendOutcome.sent;
    } on BotSendException catch (e) {
      _log('/send to $target refused by the runtime: ${e.message}');
      return SendOutcome.forbidden;
    } catch (e) {
      _log('/send to $target failed: $e');
      return SendOutcome.failed;
    }
  }

  /// The /react path: [emoji] ('' = remove) on [messageId] in [to], an
  /// owner's handle (1:1) or a group id the bot is in, the same targets
  /// /send allows. A null [messageId] means the last message received there
  /// ([SendOutcome.noMessage] when none is known).
  ///
  /// WHY a group reaction is not counted as a bot turn, unlike a group
  /// /send: a reaction addresses nobody, and bots only hear reactions to
  /// their own messages, never turned into a reply (bridges forward only
  /// owners' reactions), so it cannot feed a bot-to-bot exchange.
  Future<SendOutcome> reactFromLocal(
    String to,
    String? messageId,
    String emoji,
  ) async {
    final target = to.trim();
    final handle = target.toUpperCase();
    final String key;
    if (_handlePattern.hasMatch(handle)) {
      // Owners only, as for /send.
      if (!_allowedHandles.contains(handle) ||
          !_allowedIds.containsValue(handle)) {
        return SendOutcome.forbidden;
      }
      key = handle;
    } else {
      if (target.toLowerCase().startsWith(channelTargetPrefix)) {
        return SendOutcome.badTarget; // channel posts take no reactions
      }
      try {
        if (!(await bot.group(target)).isMember(bot.deviceId)) {
          return SendOutcome.forbidden;
        }
      } catch (_) {
        return SendOutcome.forbidden; // unknown group or not a member
      }
      key = target.toLowerCase();
    }
    final id = messageId ?? _lastReceived[key];
    if (id == null) return SendOutcome.noMessage;
    try {
      await bot.sendReaction(to: target, targetMessageId: id, emoji: emoji);
      return SendOutcome.sent;
    } on BotSendException catch (e) {
      _log('/react to $target refused by the runtime: ${e.message}');
      return SendOutcome.forbidden;
    } on ArgumentError catch (e) {
      _log('/react to $target: $e');
      return SendOutcome.badTarget;
    } catch (e) {
      _log('/react to $target failed: $e');
      return SendOutcome.failed;
    }
  }

  static final _channelHandlePattern = RegExp(
    r'^CH-[A-Z0-9]{4}-[A-Z0-9]{4}$',
    caseSensitive: false,
  );
  static final _guidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  /// `/send` to a channel (a newsletter): one post, published as the bot.
  ///
  /// WHY no owner or bot-talk check here, unlike groups: the channel OWNER
  /// decided by making the bot a publisher, and the server enforces that
  /// role, suspension and the daily bot limit on every post. A channel has
  /// no bot exchange that a post could feed, so it is not a group bot turn.
  /// WHY one post and no splitting: each post counts against the daily
  /// limit, so too long text is refused (400) instead of burning it.
  Future<SendOutcome> _sendToChannel(String channel, String text) async {
    // Only the two shapes the server knows: anything else (a path segment,
    // a typo'd prefix) is the caller's mistake, said as 400 without a
    // round trip.
    if (!_channelHandlePattern.hasMatch(channel) &&
        !_guidPattern.hasMatch(channel)) {
      _log('/send: bad channel target "$channel"');
      return SendOutcome.badTarget;
    }
    if (text.length > channelPostMaxChars) {
      _log(
        '/send to channel $channel refused: ${text.length} characters, '
        'a post takes at most $channelPostMaxChars',
      );
      return SendOutcome.textTooLong;
    }
    try {
      final postId = await bot.postToChannel(channel, text);
      _log('/send: posted $postId to channel $channel');
      return SendOutcome.sent;
    } on BotSendException catch (e) {
      _log('/send to channel $channel refused by the server: $e');
      return switch (e.statusCode) {
        429 => SendOutcome.rateLimited,
        404 => SendOutcome.badTarget,
        _ when e.code == channelSuspendedCode => SendOutcome.channelSuspended,
        _ => SendOutcome.forbidden,
      };
    } catch (e) {
      _log('/send to channel $channel failed: $e');
      return SendOutcome.failed;
    }
  }
}

/// `/send` target prefix for a channel post: `channel:CH-XXXX-XXXX` or
/// `channel:<channel id>`. A prefix, because a channel id is a GUID just
/// like a group id and the two must not be confused.
const channelTargetPrefix = 'channel:';

/// Wires [bot] to [backend], guarded by the handle allowlist and the groups'
/// bot-talk settings.
///
/// WHY fail-closed: Hermes has a terminal and tools. Anyone who learns the
/// bot's handle can message it, so "no allowlist" must mean "nobody", never
/// "everybody". Disallowed senders are dropped by the runtime BEFORE
/// decryption: no backend call, no reply, no typing indicator.
///
/// Other bots are answered only in groups, under [BotTalkPolicy] (the group
/// owner's setting, an owner of this bot as group admin, the turn limit
/// capped at [peerTurnsCap], the pause). [peerHandles] (env PEER_BOT_HANDLES)
/// optionally NARROWS that to the named bots; it can never widen it.
///
/// Give either [stream] (events: progress, approvals, answer) or the simple
/// [backend]. [approve] answers approval buttons; without it a press is
/// refused as no longer pending.
///
/// [reactions] decides what an owner's emoji reaction does (see
/// [ReactionMode]); other senders' reactions are never forwarded.
Future<HermesBridge> runBridge(
  CallTypeBot bot, {
  required Set<String> allowedHandles,
  Set<String> peerHandles = const {},
  int peerTurnsCap = 50,
  DateTime Function()? now,
  Backend? backend,
  StreamingBackend? stream,
  ApprovalBackend? approve,
  ProgressSettings progress = const ProgressSettings(),
  ReactionMode reactions = ReactionMode.silent,
  required void Function(String) log,
}) async {
  if (stream == null && backend == null) {
    throw ArgumentError('runBridge needs a backend or a stream');
  }
  final StreamingBackend turns =
      stream ??
      (text, {required conversationId}) => Stream.fromFuture(
        backend!(
          text,
          conversationId: conversationId,
        ).then<HermesEvent>(HermesCompleted.new),
      );
  // Incoming messages carry device ids, not handles, so resolve once here.
  // ponytail: resolved at startup only; restart the bridge after changing
  // ALLOWED_HANDLES / PEER_BOT_HANDLES (or after someone re-installs and gets
  // a new id).
  final allowedIds = <String, String>{}; // device id (lower-case) -> handle
  final peerIds = <String>{};
  for (final handle in allowedHandles) {
    final id = await bot.deviceIdForHandle(handle);
    id == null
        ? log('ALLOWED_HANDLES: $handle is unknown to the server, ignored.')
        : allowedIds[id.toLowerCase()] = handle;
  }
  for (final handle in peerHandles) {
    final id = await bot.deviceIdForHandle(handle);
    id == null
        ? log('PEER_BOT_HANDLES: $handle is unknown to the server, ignored.')
        : peerIds.add(id.toLowerCase());
  }
  if (allowedIds.isEmpty) {
    log(
      'ALLOWED_HANDLES is empty (or nothing resolved): the bot will reply '
      'to NOBODY. Set ALLOWED_HANDLES=CT-XXXX-XXXX[,CT-...] to your own Jay '
      'handle(s) (Settings -> Identity) and restart.',
    );
  }

  final bridge = HermesBridge._(
    bot,
    BotTalkPolicy(
      selfDeviceId: bot.deviceId,
      ownerIds: allowedIds.keys.toSet(),
      // Set but nothing resolved = an empty filter = no peer at all: the
      // operator asked to narrow, so failing to resolve must not widen.
      peerFilter: peerHandles.isEmpty ? null : peerIds,
      turnsCap: peerTurnsCap,
      now: now,
    ),
    allowedIds,
    allowedHandles,
    turns,
    approve,
    progress,
    log,
    reactions,
  );
  // Before onMessage: that call connects, and queued presses arrive at once.
  bot.onAction(bridge._onAction);
  if (reactions != ReactionMode.off) bot.onReaction(bridge._onReaction);
  await bot.onMessage(
    bridge._handle,
    allowSender: bridge._allowSender,
    allowGroupSender: bridge._admitGroupBot,
  );
  return bridge;
}
