import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:calltype_bot/calltype_bot.dart';

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

/// What to do with a peer-bot message, see [PeerRateLimiter.check].
enum PeerVerdict { allow, notify, drop }

/// Sliding-window brake on bot-to-bot turns, per conversation.
///
/// WHY: two agents that may talk to each other can answer each other forever
/// and burn tokens. A human message ([reset]) is the only thing that re-arms
/// the conversation early. The clock is injected so tests need no timers.
// ponytail: in-memory only, counters reset on restart. Persist them if a
// restart loop ever becomes a way around the limit.
class PeerRateLimiter {
  PeerRateLimiter({
    required this.limit,
    required this.window,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final int limit;
  final Duration window;
  final DateTime Function() _now;
  final _turns = <String, List<DateTime>>{};
  final _notified = <String>{};

  /// [allow] counts one turn; [notify] is the FIRST refusal of an exhausted
  /// window (caller sends the notice); [drop] is every later refusal.
  PeerVerdict check(String conversationId) {
    final now = _now();
    final turns = _turns.putIfAbsent(conversationId, () => []);
    turns.removeWhere((t) => now.difference(t) >= window);
    if (turns.length < limit) {
      turns.add(now);
      _notified.remove(conversationId); // window slid: notice can fire again
      return PeerVerdict.allow;
    }
    return _notified.add(conversationId) ? PeerVerdict.notify : PeerVerdict.drop;
  }

  /// A human spoke: forget the count and the "notice sent" flag.
  void reset(String conversationId) {
    _turns.remove(conversationId);
    _notified.remove(conversationId);
  }
}

/// Wires [bot] to [backend], guarded by the handle allowlist.
///
/// WHY fail-closed: Hermes has a terminal and tools. Anyone who learns the
/// bot's handle can message it, so "no allowlist" must mean "nobody", never
/// "everybody". Disallowed senders are dropped by the runtime BEFORE
/// decryption — no backend call, no reply, no typing indicator.
///
/// [peerHandles] is a second allowlist of other bots, accepted in groups only
/// and throttled to [peerReplyLimit] turns per [peerReplyWindow] per
/// conversation until a human writes again.
Future<void> runBridge(
  CallTypeBot bot, {
  required Set<String> allowedHandles,
  Set<String> peerHandles = const {},
  int peerReplyLimit = 5,
  Duration peerReplyWindow = const Duration(minutes: 30),
  DateTime Function()? now,
  required Backend backend,
  required void Function(String) log,
}) async {
  // Incoming messages carry device ids, not handles, so resolve once here.
  // ponytail: resolved at startup only — restart the bridge after changing
  // ALLOWED_HANDLES / PEER_BOT_HANDLES (or after someone re-installs and gets
  // a new id).
  final allowedIds = <String, String>{}; // device id -> handle
  final peerIds = <String, String>{};
  Future<void> resolve(
    String name,
    Set<String> handles,
    Map<String, String> into,
  ) async {
    for (final handle in handles) {
      final id = await bot.deviceIdForHandle(handle);
      id == null
          ? log('$name: $handle is unknown to the server — ignored.')
          : into[id] = handle;
    }
  }

  await resolve('ALLOWED_HANDLES', allowedHandles, allowedIds);
  await resolve('PEER_BOT_HANDLES', peerHandles, peerIds);
  if (allowedIds.isEmpty) {
    log(
      'ALLOWED_HANDLES is empty (or nothing resolved): the bot will reply '
      'to NOBODY. Set ALLOWED_HANDLES=CT-XXXX-XXXX[,CT-…] to your own Jay '
      'handle(s) (Settings -> Identity) and restart.',
    );
  }

  final limiter = PeerRateLimiter(
    limit: peerReplyLimit,
    window: peerReplyWindow,
    now: now,
  );
  final notice =
      'Bot-to-bot limit reached ($peerReplyLimit per '
      '${peerReplyWindow.inMinutes} min). Waiting for a human to mention me.';

  await bot.onMessage((message) async {
    // In groups the runtime only calls this handler for messages that mention
    // the bot, so only a human message WITH a mention re-arms the limit.
    final human = allowedIds[message.senderId];
    if (human != null) {
      limiter.reset(message.conversationId);
    } else {
      // WHY groups only: a 1:1 bot-to-bot chat has no human watching it.
      if (!message.isGroup) return;
      switch (limiter.check(message.conversationId)) {
        case PeerVerdict.drop:
          return;
        case PeerVerdict.notify:
          await message.reply(notice);
          return;
        case PeerVerdict.allow:
          break;
      }
    }
    // The prefix tells the agent who is speaking (and that it is a bot).
    final label = human != null
        ? '[from $human]'
        : '[from ${peerIds[message.senderId]} (bot)]';
    final reply = await backend(
      '$label: ${message.text}',
      conversationId: message.conversationId,
    );
    for (final chunk in splitMessage(reply)) {
      await message.reply(chunk);
    }
  }, allowSender: (id) => allowedIds.containsKey(id) || peerIds.containsKey(id));
}
