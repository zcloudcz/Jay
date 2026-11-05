import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:calltype_bot/calltype_bot.dart';

import 'src/bot_talk.dart';
import 'src/send_endpoint.dart';

export 'src/bot_talk.dart';
export 'src/send_endpoint.dart';

/// Answers one user message within a conversation. The only thing the
/// bridge needs from a backend, so swapping Hermes for something else (or a
/// fake in tests) is one function.
typedef Backend =
    Future<String> Function(String text, {required String conversationId});

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
  }) : _base = Uri.parse(baseUrl.endsWith('/') ? baseUrl : '$baseUrl/');

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

/// The one notice a bot posts when a bot-only exchange hits its limit.
const botLimitNotice = 'Bot limit reached, waiting for a human.';

/// The running bridge: the message handler and the local send path share its
/// [policy], so a message started via /send counts as a bot turn too.
class HermesBridge {
  HermesBridge._(
    this.bot,
    this.policy,
    this._allowedIds,
    this._allowedHandles,
    this._backend,
    this._log,
  );

  final CallTypeBot bot;
  final BotTalkPolicy policy;

  /// Owner device id (lower-case) -> handle.
  final Map<String, String> _allowedIds;
  final Set<String> _allowedHandles;
  final Backend _backend;
  final void Function(String) _log;

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
    String label;
    if (human != null) {
      // In groups the runtime only calls this handler for messages that
      // mention the bot, so only a human message WITH a mention re-arms.
      if (groupId != null) policy.humanSpoke(groupId);
      label = '[from $human]';
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
          await message.reply(botLimitNotice);
          return;
        case PeerVerdict.allow:
          break;
      }
      final peer = group.member(message.senderId);
      label =
          '[from ${peer?.handle ?? peer?.displayName ?? message.senderId} (bot)]';
    }
    // The prefix tells the agent who is speaking (and that it is a bot).
    final reply = await _backend(
      '$label: ${message.text}',
      conversationId: message.conversationId,
    );
    for (final chunk in splitMessage(reply)) {
      await message.reply(chunk);
    }
  }

  /// The /send path: [to] is an owner's handle (1:1) or a group id the bot is
  /// in. A group post is a bot turn: refused (403) once the exchange limit or
  /// the pause says so. Long text goes out in [splitMessage] chunks; the
  /// chunks of one request are ONE turn.
  Future<SendOutcome> sendFromLocal(String to, String text) async {
    final target = to.trim();
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
}

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
Future<HermesBridge> runBridge(
  CallTypeBot bot, {
  required Set<String> allowedHandles,
  Set<String> peerHandles = const {},
  int peerTurnsCap = 50,
  DateTime Function()? now,
  required Backend backend,
  required void Function(String) log,
}) async {
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
    backend,
    log,
  );
  await bot.onMessage(
    bridge._handle,
    allowSender: bridge._allowSender,
    allowGroupSender: bridge._admitGroupBot,
  );
  return bridge;
}
