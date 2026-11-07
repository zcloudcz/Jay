import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Files and voice in the agent's replies (README "Sending files and voice
/// replies"): file references in the answer text, the allowed roots they
/// must live under, the voice reply decision and the text-to-speech call.

/// One file the agent asked to send.
class FileRef {
  const FileRef(this.path, {this.voice = false});

  /// As written (after `~/` expansion); checked by [FileRoots] later.
  final String path;

  /// Send as a voice message (`[voice:/path]`, or an audio file with
  /// Hermes' `[[audio_as_voice]]`).
  final bool voice;

  @override
  bool operator ==(Object other) =>
      other is FileRef && other.path == path && other.voice == voice;
  @override
  int get hashCode => Object.hash(path, voice);
  @override
  String toString() => 'FileRef($path${voice ? ', voice' : ''})';
}

/// What [parseOutgoingDirectives] found in a reply.
typedef OutgoingDirectives = ({
  /// The reply without the directives.
  String text,
  List<FileRef> files,

  /// `[voice]`: the agent wants its answer spoken.
  bool voice,
});

/// `MEDIA:<path>` (Hermes' convention, path optionally quoted with backticks
/// or quotes), `[file:/path]`, `[voice:/path]`, `[voice]`, Hermes'
/// `[[audio_as_voice]]` / `[[as_document]]` markers, or an inline code span
/// (matched only to be skipped: examples in code are never delivered).
final _token = RegExp(
  r'(?<code>`[^`\n]*`)'
  r'''|MEDIA:[ \t]*(?<media>`[^`\n]+`|"[^"\n]+"|'[^'\n]+'|(?:~/|/)\S+)'''
  r'|\[[ \t]*(?<kind>file|voice)[ \t]*:[ \t]*(?<path>[^\]\n]+?)[ \t]*\]'
  r'|(?<bare>\[[ \t]*voice[ \t]*\])'
  r'|(?<asVoice>\[\[audio_as_voice\]\])'
  r'|(?<asDoc>\[\[as_document\]\])',
  caseSensitive: false,
);

/// A whole line `MEDIA: /path with spaces/file.pdf`.
final _mediaLine = RegExp(r'^[ \t]*MEDIA:[ \t]*((?:~/|/).*?)[ \t]*$');

const _audioExtensions = {
  'mp3', 'm4a', 'aac', 'wav', 'ogg', 'oga', 'opus', 'flac', 'webm', //
};

/// Splits file references and the voice directive out of [reply].
///
/// Skipped (left as text, never delivered): fenced code blocks, inline code
/// spans and quoted lines (`> ...`), so the agent can show the syntax.
/// [exists] decides whether a whole `MEDIA:` line with spaces is one path.
OutgoingDirectives parseOutgoingDirectives(
  String reply, {
  bool Function(String path)? exists,
  String? home,
}) {
  exists ??= (p) => File(p).existsSync();
  home ??= Platform.environment['HOME'] ?? '';
  final out = StringBuffer();
  final found = <(String, bool)>[];
  var voice = false;
  var asVoice = false;
  var fenced = false;
  String expand(String p) => p.startsWith('~/') ? '$home${p.substring(1)}' : p;
  final lines = reply.split('\n');
  for (var n = 0; n < lines.length; n++) {
    final line = lines[n];
    final eol = n < lines.length - 1 ? '\n' : '';
    if (line.trimLeft().startsWith('```')) {
      fenced = !fenced;
      out.write('$line$eol');
      continue;
    }
    if (fenced || line.trimLeft().startsWith('>')) {
      out.write('$line$eol');
      continue;
    }
    final whole = _mediaLine.firstMatch(line.replaceAll('\r', ''));
    if (whole != null &&
        whole.group(1)!.contains(RegExp(r'\s')) &&
        exists(expand(whole.group(1)!))) {
      found.add((expand(whole.group(1)!), false));
      continue; // the line is only the tag: drop it
    }
    final kept = StringBuffer();
    var at = 0;
    var removed = false;
    for (final m in _token.allMatches(line)) {
      if (m.namedGroup('code') != null) continue;
      kept.write(line.substring(at, m.start));
      at = m.end;
      removed = true;
      final media = m.namedGroup('media');
      final kind = m.namedGroup('kind');
      if (media != null) {
        found.add((expand(_unquote(media)), false));
      } else if (kind != null) {
        found.add((
          expand(_unquote(m.namedGroup('path')!)),
          kind.toLowerCase() == 'voice',
        ));
      } else if (m.namedGroup('bare') != null) {
        voice = true;
      } else if (m.namedGroup('asVoice') != null) {
        asVoice = true;
      }
    }
    kept.write(line.substring(at));
    final rest = kept.toString();
    // A line that held only directives disappears instead of leaving a
    // blank line behind.
    if (removed && rest.trim().isEmpty) continue;
    out.write('${removed ? rest.trimRight() : line}$eol');
  }
  final files = <FileRef>[];
  final seen = <String>{};
  for (final (path, isVoice) in found) {
    if (!seen.add(path)) continue;
    final dot = path.lastIndexOf('.');
    final ext = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
    files.add(
      FileRef(
        path,
        voice: isVoice || (asVoice && _audioExtensions.contains(ext)),
      ),
    );
  }
  final text = out.toString().replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  return (
    text: found.isEmpty && !voice && !asVoice ? reply : text,
    files: files,
    voice: voice,
  );
}

/// Quotes around a path come off; an unquoted one loses trailing
/// punctuation of the sentence it ends (`see MEDIA:/tmp/a.png.`).
String _unquote(String raw) {
  final t = raw.trim();
  if (t.length >= 2) {
    final q = t[0];
    if ((q == '`' || q == '"' || q == "'") && t.endsWith(q)) {
      return t.substring(1, t.length - 1).trim();
    }
  }
  return t.replaceFirst(RegExp(r'''[.,;:!?)\]}'"*_`]+$'''), '');
}

/// Why a file reference was not sent.
class FileRefused implements Exception {
  const FileRefused(this.reason);

  /// Czech, shown to the user (it is the agent's file, the owner reads why).
  final String reason;
  @override
  String toString() => 'FileRefused: $reason';
}

/// The directories files may be sent from (env `MEDIA_SEND_ROOTS`).
///
/// WHY: the agent's reply is untrusted text (a prompt injection in a web
/// page could ask it to "attach" `~/.ssh/id_rsa` or the bridge env). A file
/// is sent only when its REAL path (symlinks and `..` resolved) lies inside
/// a root, so neither `../` nor a symlink inside a root leads out of it.
class FileRoots {
  FileRoots(List<String> roots, {required this.maxBytes})
    : _roots = [
        for (final r in roots)
          if (r.trim().isNotEmpty) r.trim(),
      ];

  final List<String> _roots;
  final int maxBytes;

  List<String> get configured => List.unmodifiable(_roots);

  /// Real paths of the roots that exist now (resolved per call: a root
  /// created after the start counts).
  Future<List<String>> _realRoots() async {
    final real = <String>[];
    for (final root in _roots) {
      try {
        final dir = Directory(root);
        if (await dir.exists()) {
          var path = await dir.resolveSymbolicLinks();
          if (path.length > 1 && path.endsWith('/')) {
            path = path.substring(0, path.length - 1);
          }
          real.add(path);
        }
      } catch (_) {}
    }
    return real;
  }

  /// The real path of [path] when it may be sent, else [FileRefused].
  Future<String> check(String path) async {
    if (!path.startsWith('/')) {
      throw const FileRefused('cesta není absolutní');
    }
    final String real;
    try {
      if (await FileSystemEntity.type(path) != FileSystemEntityType.file) {
        throw const FileRefused('soubor neexistuje');
      }
      real = await File(path).resolveSymbolicLinks();
    } on FileSystemException {
      throw const FileRefused('soubor neexistuje');
    }
    final roots = await _realRoots();
    final inside = roots.any(
      (root) => real.startsWith(root == '/' ? '/' : '$root/'),
    );
    if (!inside) {
      throw const FileRefused('mimo povolené složky');
    }
    if (await FileSystemEntity.type(real, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FileRefused('není to běžný soubor');
    }
    final size = await File(real).length();
    if (size > maxBytes) {
      throw FileRefused('nad limit ${(maxBytes / 1e6).toStringAsFixed(0)} MB');
    }
    return real;
  }
}

/// When the bridge answers with a voice message (env `VOICE_REPLY_MODE`).
enum VoiceReplyMode {
  /// When the owner sent a voice message, asked for a voice reply, or the
  /// agent wrote `[voice]` (default).
  auto,

  /// Every answer to an owner.
  always,

  /// Never; `[voice]` is stripped and ignored.
  off,
}

/// `VOICE_REPLY_MODE` -> [VoiceReplyMode]; empty = auto. Throws
/// [FormatException] for anything else, so a typo stops the start.
VoiceReplyMode parseVoiceReplyMode(String? raw) {
  final value = (raw ?? '').trim().toLowerCase();
  if (value.isEmpty) return VoiceReplyMode.auto;
  for (final mode in VoiceReplyMode.values) {
    if (mode.name == value) return mode;
  }
  throw FormatException(
    'VOICE_REPLY_MODE must be one of auto, always, off, got "$raw"',
  );
}

/// The owner asks for the answer as a voice message ("odpověz hlasovkou",
/// "pošli mi to hlasovou zprávou", "reply with a voice message").
final _asksForVoice = RegExp(
  r'hlasovk(ou|u)\b|hlasovou\s+zpr[aá]v(ou|u)|namluv|'
  r'\b(reply|answer|respond)\s+(with|by|in)\s+(a\s+)?voice|\bvoice\s+(reply|answer)',
  caseSensitive: false,
);

bool asksForVoiceReply(String text) => _asksForVoice.hasMatch(text);

/// Whether a turn's answer also goes out as a voice message.
bool wantsVoiceReply(
  VoiceReplyMode mode, {
  required bool userSentVoice,
  required bool userAskedForVoice,
  required bool agentDirective,
}) => switch (mode) {
  VoiceReplyMode.off => false,
  VoiceReplyMode.always => true,
  VoiceReplyMode.auto => userSentVoice || userAskedForVoice || agentDirective,
};

/// Turns [text] into speech in an audio file at [outPath] (MP3);
/// [ElevenLabsTts] in production, a fake in tests.
typedef Speaker = Future<File> Function(String text, String outPath);

/// What a reply sounds like: markdown, code and links do not read aloud.
/// Longer than [maxChars] is cut at the last sentence end before it.
String speechText(String text, {int maxChars = 2500}) {
  var t = text
      .replaceAll(RegExp(r'```[\s\S]*?(```|$)'), ' ')
      .replaceAllMapped(RegExp(r'\[([^\]\n]+)\]\([^)\s]+\)'), (m) => m[1]!)
      .replaceAll(RegExp(r'https?://\S+'), ' ')
      .replaceAll(RegExp(r'`'), '')
      .replaceAll(
        RegExp(r'^[ \t]*(#{1,6}|>|[-*+]|\d+\.)[ \t]+', multiLine: true),
        '',
      )
      .replaceAll(RegExp(r'(\*\*|__|\*|~~)'), '')
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .join('\n');
  if (t.length > maxChars) {
    final cut = t.substring(0, maxChars);
    final end = cut.lastIndexOf(RegExp(r'[.!?…](\s|$)'));
    t = (end > maxChars ~/ 2 ? cut.substring(0, end + 1) : cut).trim();
  }
  return t;
}

/// ElevenLabs Text-to-Speech (`POST /v1/text-to-speech/{voice_id}`), MP3
/// out; the bot runtime converts it to the app's voice format (AAC .m4a)
/// when ffmpeg is there.
class ElevenLabsTts {
  ElevenLabsTts({
    required this.apiKey,
    required this.voiceId,
    this.model = 'eleven_v4',
    this.outputFormat = 'mp3_44100_128',
    String baseUrl = 'https://api.elevenlabs.io',
    this.timeout = const Duration(minutes: 2),
  }) : _base = Uri.parse(baseUrl.endsWith('/') ? baseUrl : '$baseUrl/');

  final String apiKey;
  final String voiceId;
  final String model;
  final String outputFormat;
  final Duration timeout;
  final Uri _base;
  final _http = HttpClient();

  Future<File> call(String text, String outPath) async {
    final uri = _base
        .resolve('v1/text-to-speech/${Uri.encodeComponent(voiceId)}')
        .replace(queryParameters: {'output_format': outputFormat});
    final request = await _http.postUrl(uri).timeout(timeout);
    request.headers.set('xi-api-key', apiKey);
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.acceptHeader, 'audio/mpeg');
    request.add(utf8.encode(jsonEncode({'text': text, 'model_id': model})));
    final response = await request.close().timeout(timeout);
    if (response.statusCode != 200) {
      final body = await utf8.decodeStream(response).timeout(timeout);
      String detail = '';
      try {
        final json = jsonDecode(body);
        final d = json is Map ? json['detail'] : null;
        detail = d is Map ? ' ${d['status'] ?? d['code'] ?? ''}' : '';
      } catch (_) {}
      throw HttpException('ElevenLabs TTS: HTTP ${response.statusCode}$detail');
    }
    final file = File(outPath);
    final sink = file.openWrite();
    try {
      await sink.addStream(response.timeout(timeout));
    } finally {
      await sink.close();
    }
    if (await file.length() == 0) {
      await file.delete();
      throw const FormatException('ElevenLabs TTS: empty audio');
    }
    return file;
  }

  void close() => _http.close(force: true);
}

/// Sending side of the bridge: where files may come from, the voice reply
/// rules and the TTS (env, see bin/hermes_bridge.dart).
class OutgoingMedia {
  OutgoingMedia({
    required this.roots,
    required this.ttsDir,
    this.speak,
    this.voiceMode = VoiceReplyMode.auto,
    this.voiceWithText = true,
    this.ttsMaxChars = 2500,
    this.captionMaxChars = 1024,
    required this.log,
  });

  final FileRoots roots;

  /// Where TTS audio is written before it is sent (deleted after sending).
  final String ttsDir;

  /// Null = no TTS configured: no voice replies, `[voice]` is ignored.
  final Speaker? speak;
  final VoiceReplyMode voiceMode;

  /// A voice reply also posts the text (default); false = voice only (the
  /// text still goes out when the TTS fails or the text is too long).
  final bool voiceWithText;
  final int ttsMaxChars;

  /// A reply with one file and at most this much text sends the text as
  /// the file's caption instead of a separate message.
  final int captionMaxChars;
  final void Function(String) log;

  bool get canSpeak => speak != null && voiceMode != VoiceReplyMode.off;

  static int _counter = 0;

  /// Speaks [text] (see [speechText]) into a new MP3 under [ttsDir].
  Future<File> tts(String text) async {
    final speaker = speak;
    if (speaker == null) throw StateError('no TTS configured');
    final spoken = speechText(text, maxChars: ttsMaxChars);
    if (spoken.isEmpty) throw const FormatException('nothing to speak');
    final dir = Directory(ttsDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
      if (!Platform.isWindows) {
        try {
          await Process.run('chmod', ['700', dir.path]);
        } catch (_) {}
      }
    }
    final name =
        'tts-${DateTime.now().millisecondsSinceEpoch}-${_counter++}.mp3';
    return speaker(spoken, '${dir.path}/$name');
  }
}
