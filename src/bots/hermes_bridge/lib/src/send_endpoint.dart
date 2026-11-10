import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:calltype_bot/calltype_bot.dart'
    show MediaKind, isValidReactionEmoji, maxReactionTargetLength;

/// Result of a local send request, see [startSendEndpoint].
enum SendOutcome {
  sent,

  /// The bridge's rules do not allow this target (or it cannot be verified).
  forbidden,

  /// The target channel is suspended by moderation (server 403
  /// `channel_suspended`). Its own value so a cron job can tell "stop
  /// posting" apart from "the bot was never made a publisher".
  channelSuspended,

  /// The server's daily bot post limit for the channel is used up (429
  /// `bot_post_limit`); retrying today is pointless.
  rateLimited,

  /// Malformed or unknown target (e.g. `channel:` without a valid handle).
  badTarget,

  /// Text longer than one channel post may be (4096 characters).
  textTooLong,

  /// `/react` without a messageId, and no message from that target is
  /// known yet (the bridge remembers the last one in memory only).
  noMessage,

  /// Allowed, but delivery to the hub failed.
  failed,

  /// `file` outside the allowed roots (`MEDIA_SEND_ROOTS`), missing, or not
  /// a regular file.
  fileNotAllowed,

  /// `file` larger than `MEDIA_SEND_MAX_BYTES` (or the server cap).
  fileTooLarge,

  /// Files are off, or `voice` was asked without a TTS key / voice id.
  mediaUnavailable,
}

/// `/send` with a file or a voice message: `{"to", "file"?, "kind"?,
/// "caption"?, "voice"?, "text"?}`.
class LocalMediaRequest {
  const LocalMediaRequest({
    required this.to,
    this.text,
    this.file,
    this.kind,
    this.caption,
    this.voice = false,
  });

  final String to;

  /// With [file]: posted as a normal message first. Without: with [voice]
  /// it is spoken (TTS) and sent as a voice message.
  final String? text;

  /// Absolute path under the allowed roots.
  final String? file;

  /// Forced kind; null = from the file name / type.
  final MediaKind? kind;
  final String? caption;

  /// Send as a voice message (the file, or [text] spoken).
  final bool voice;
}

typedef LocalSendMedia =
    Future<SendOutcome> Function(LocalMediaRequest request);

typedef LocalSend = Future<SendOutcome> Function(String to, String text);

/// Puts [emoji] ('' = remove) on [messageId] in the conversation [to]; a
/// null [messageId] means the last message received from [to].
typedef LocalReact =
    Future<SendOutcome> Function(String to, String? messageId, String emoji);

/// Largest accepted request body. A chat message, not a file upload.
const maxSendBodyBytes = 256 * 1024;

/// Starts `POST /send` (and `POST /react` when [react] is given) on
/// 127.0.0.1:[port] so local tools and cron jobs can post into Jay through
/// the bridge.
///
/// WHY fail-closed: anything on the host could reach a loopback port, and the
/// bot speaks with its owner's trust. Without a [key] there is no endpoint at
/// all (returns null), never an open one. Both routes share the key, the
/// constant-time check, the body cap and the error style.
///
/// `/send {"to", "text"}`: 202 sent, 400 bad body or bad target, 401 bad
/// key, 403 target not allowed (or channel suspended), 404 unknown path, 405
/// wrong method, 429 bot post limit of a channel, 502 delivery failed.
///
/// `/react {"to", "messageId"?, "emoji"}`: 202 reacted, 400 bad body,
/// invalid emoji or bad target, 401, 403 target not allowed, 404 no known
/// message to react to, 502 delivery failed.
Future<HttpServer?> startSendEndpoint({
  required String? key,
  required LocalSend send,
  LocalSendMedia? sendMedia,
  LocalReact? react,
  required void Function(String) log,
  int port = 8650,
}) async {
  if (key == null || key.trim().isEmpty) return null;
  final expected = utf8.encode('Bearer ${key.trim()}');
  final routes = <String, _Route>{
    '/send': (json) => _send(json, send, sendMedia),
    if (react != null) '/react': (json) => _react(json, react),
  };
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  server.listen((request) async {
    final path = request.uri.path;
    try {
      final (status, body) = await _serve(request, expected, routes, log);
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(body));
    } catch (e) {
      log('$path: internal error: $e');
      request.response.statusCode = HttpStatus.internalServerError;
    }
    await request.response.close();
  });
  log(
    'Local endpoint on http://127.0.0.1:${server.port}: '
    '${routes.keys.join(', ')}',
  );
  return server;
}

/// One route: the parsed JSON object of an authenticated request in, the
/// status and body out.
typedef _Route = Future<(int, Object)> Function(Map<dynamic, dynamic> json);

/// What every route shares: path, method, key, body cap, JSON object.
Future<(int, Object)> _serve(
  HttpRequest request,
  List<int> expectedAuth,
  Map<String, _Route> routes,
  void Function(String) log,
) async {
  final path = request.uri.path;
  final route = routes[path];
  if (route == null) return (404, {'error': 'not_found'});
  if (request.method != 'POST') return (405, {'error': 'method_not_allowed'});
  final auth = request.headers.value(HttpHeaders.authorizationHeader) ?? '';
  if (!_constantTimeEquals(utf8.encode(auth), expectedAuth)) {
    // The key itself is never logged.
    log('$path: rejected a request with a wrong or missing key');
    return (401, {'error': 'unauthorized'});
  }
  final bytes = <int>[];
  await for (final chunk in request) {
    bytes.addAll(chunk);
    if (bytes.length > maxSendBodyBytes) return (400, {'error': 'too_large'});
  }
  final Object? json;
  try {
    json = jsonDecode(utf8.decode(bytes));
  } on FormatException {
    return (400, {'error': 'invalid_json'});
  }
  if (json is! Map) return (400, {'error': 'expected a JSON object'});
  return route(json);
}

const _mediaKeys = {'file', 'kind', 'caption', 'voice'};

Future<(int, Object)> _send(
  Map<dynamic, dynamic> json,
  LocalSend send,
  LocalSendMedia? sendMedia,
) async {
  if (json.keys.any(_mediaKeys.contains)) {
    if (sendMedia == null) return (400, {'error': 'files_unsupported'});
    return _sendMedia(json, sendMedia);
  }
  final to = json['to'];
  final text = json['text'];
  if (to is! String ||
      text is! String ||
      to.trim().isEmpty ||
      text.trim().isEmpty) {
    return (400, {'error': 'expected {"to": string, "text": string}'});
  }
  return _answer(await send(to.trim(), text), 'sent');
}

Future<(int, Object)> _sendMedia(
  Map<dynamic, dynamic> json,
  LocalSendMedia sendMedia,
) async {
  const usage =
      'expected {"to": string, "file"?: absolute path, "kind"?: '
      'image|video|audio|voice|file, "caption"?: string, "voice"?: bool, '
      '"text"?: string} with a file, or with voice and text';
  final to = json['to'];
  final text = json['text'];
  final file = json['file'];
  final kind = json['kind'];
  final caption = json['caption'];
  final voice = json['voice'] ?? false;
  if (to is! String ||
      to.trim().isEmpty ||
      (text != null && text is! String) ||
      (file != null && (file is! String || !file.startsWith('/'))) ||
      (kind != null &&
          (kind is! String || !MediaKind.values.any((k) => k.name == kind))) ||
      (caption != null && (caption is! String || caption.length > 4096)) ||
      voice is! bool) {
    return (400, {'error': usage});
  }
  final hasText = text is String && text.trim().isNotEmpty;
  if (file == null && !(voice && hasText)) {
    return (400, {'error': usage});
  }
  return _answer(
    await sendMedia(
      LocalMediaRequest(
        to: to.trim(),
        text: text as String?,
        file: file as String?,
        kind: kind == null ? null : MediaKind.parse(kind),
        caption: caption as String?,
        voice: voice,
      ),
    ),
    'sent',
  );
}

Future<(int, Object)> _react(
  Map<dynamic, dynamic> json,
  LocalReact react,
) async {
  final to = json['to'];
  final messageId = json['messageId'];
  final emoji = json['emoji'];
  if (to is! String ||
      to.trim().isEmpty ||
      emoji is! String ||
      (messageId != null &&
          (messageId is! String ||
              messageId.trim().isEmpty ||
              messageId.length > maxReactionTargetLength))) {
    return (
      400,
      {
        'error':
            'expected {"to": string, "messageId"?: string, "emoji": string}',
      },
    );
  }
  if (emoji.isNotEmpty && !isValidReactionEmoji(emoji)) {
    return (400, {'error': 'invalid_emoji'});
  }
  return _answer(
    await react(to.trim(), (messageId as String?)?.trim(), emoji),
    'reacted',
  );
}

(int, Object) _answer(SendOutcome outcome, String done) => switch (outcome) {
  SendOutcome.sent => (202, {'status': done}),
  SendOutcome.forbidden => (403, {'error': 'target_not_allowed'}),
  SendOutcome.channelSuspended => (403, {'error': 'channel_suspended'}),
  SendOutcome.rateLimited => (429, {'error': 'bot_post_limit'}),
  SendOutcome.badTarget => (400, {'error': 'bad_target'}),
  SendOutcome.textTooLong => (400, {'error': 'text_too_long'}),
  SendOutcome.noMessage => (404, {'error': 'no_message'}),
  SendOutcome.failed => (502, {'error': 'delivery_failed'}),
  SendOutcome.fileNotAllowed => (403, {'error': 'file_not_allowed'}),
  SendOutcome.fileTooLarge => (413, {'error': 'file_too_large'}),
  SendOutcome.mediaUnavailable => (503, {'error': 'media_unavailable'}),
};

/// WHY constant time: a byte-by-byte early exit leaks how much of the key a
/// guess got right through response timing.
bool _constantTimeEquals(List<int> a, List<int> b) {
  var diff = a.length ^ b.length;
  for (var i = 0; i < a.length && i < b.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
