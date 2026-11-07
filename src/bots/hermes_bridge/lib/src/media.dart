import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:calltype_bot/calltype_bot.dart';

/// Turns received files into what the agent reads: voice messages as a
/// transcript, images as image input (or a saved file), everything else as
/// a saved file with its metadata. Spec: README "Voice messages, images and
/// files".

/// Transcribes [audio] (a decrypted voice message or audio file) to text.
/// [ElevenLabsTranscriber] in production; tests pass a fake.
typedef Transcriber =
    Future<String> Function(File audio, {required String mime});

/// One image for a vision-capable Hermes turn, sent as an OpenAI-style
/// `image_url` content part with a `data:` URL (what Hermes' API server
/// accepts on `/api/sessions/{id}/chat[/stream]`).
class HermesImage {
  const HermesImage({required this.mime, required this.bytes});
  final String mime;
  final Uint8List bytes;

  Map<String, Object> toContentPart() => {
    'type': 'image_url',
    'image_url': {'url': 'data:$mime;base64,${base64Encode(bytes)}'},
  };
}

/// Image types a vision model takes as input; anything else is saved as a
/// file instead.
const visionMimes = {'image/jpeg', 'image/png', 'image/gif', 'image/webp'};

/// Limits and the place received files go (env, see bin/hermes_bridge.dart).
class MediaSettings {
  const MediaSettings({
    required this.dir,
    this.maxFileBytes = 200 * 1000 * 1000,
    this.retention = const Duration(days: 7),
    this.sttMaxBytes = 25 * 1000 * 1000,
    this.sttMaxDuration = const Duration(minutes: 10),
    this.imageMaxBytes = 5 * 1000 * 1000,
    this.imageInput = true,
  });

  /// Where files are saved, one subfolder per message (mode 700).
  final String dir;

  /// Larger files are not downloaded; the agent gets only the metadata.
  final int maxFileBytes;

  /// Saved files older than this are deleted.
  final Duration retention;

  /// Voice and audio above either limit are not transcribed.
  final int sttMaxBytes;
  final Duration sttMaxDuration;

  /// Images up to this size go to Hermes as image input (Hermes' request
  /// body cap is 10 MB and the image is sent base64); larger ones are saved.
  final int imageMaxBytes;

  /// False: images are always saved and passed as a path.
  final bool imageInput;
}

/// What one received file becomes for the agent.
class MediaTurnInput {
  const MediaTurnInput(this.text, [this.images = const []]);

  /// The user's turn text (description, transcript and caption).
  final String text;
  final List<HermesImage> images;
}

/// Saves files under [MediaSettings.dir] and describes them for the agent.
class MediaProcessor {
  MediaProcessor({
    required this.settings,
    this.transcribe,
    required this.log,
    this.missingSttKeyHint = 'ELEVENLABS_API_KEY',
  });

  final MediaSettings settings;

  /// Null = no STT key configured: voice messages arrive as a note.
  final Transcriber? transcribe;
  final void Function(String) log;

  /// The env name the note about a missing STT key mentions.
  final String missingSttKeyHint;

  bool _prepared = false;

  /// Creates the media folder with mode 700 (once).
  Future<Directory> _root() async {
    final dir = Directory(settings.dir);
    if (!_prepared) {
      await dir.create(recursive: true);
      await _chmod('700', dir.path);
      _prepared = true;
    }
    return dir;
  }

  static Future<void> _chmod(String mode, String path) async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', [mode, path]);
    } catch (_) {
      // No chmod binary (a minimal image): the umask decides.
    }
  }

  /// Deletes saved message folders older than [MediaSettings.retention].
  /// Returns how many were removed.
  Future<int> cleanup({DateTime? now}) async {
    final dir = Directory(settings.dir);
    if (!await dir.exists()) return 0;
    final limit = (now ?? DateTime.now()).subtract(settings.retention);
    var removed = 0;
    await for (final entry in dir.list(followLinks: false)) {
      try {
        final stat = await entry.stat();
        if (stat.modified.isBefore(limit)) {
          await entry.delete(recursive: true);
          removed++;
        }
      } catch (e) {
        log('Media cleanup: cannot remove ${entry.path}: $e');
      }
    }
    return removed;
  }

  /// Saves [attachment] as `<dir>/<messageId>/<name>`.
  Future<File> save(String messageId, BotAttachment attachment) async {
    final root = await _root();
    final folder = Directory('${root.path}/${_safeSegment(messageId)}');
    await folder.create();
    return attachment.saveTo(
      '${folder.path}/${_safeSegment(attachment.name)}',
      maxBytes: settings.maxFileBytes,
    );
  }

  /// One path segment, whatever the sender wrote (names are validated by
  /// the runtime already; this is defence in depth).
  static String _safeSegment(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[/\\\x00-\x1f]'), '_');
    if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') return 'file';
    return cleaned;
  }

  /// The agent's view of [message]'s attachment. [download] false (a
  /// message from another bot): metadata only, nothing is fetched.
  /// [imageInput]: the backend can take images as input.
  Future<MediaTurnInput> describe(
    BotMessage message,
    BotAttachment attachment, {
    bool download = true,
    bool imageInput = false,
  }) async {
    final caption = attachment.caption;
    String withCaption(String line) =>
        caption == null ? line : '$line\n$caption';
    final size = formatMediaSize(attachment.size);
    if (!download) {
      return MediaTurnInput(withCaption(_fileLine(attachment, size, null)));
    }
    switch (attachment.kind) {
      case MediaKind.voice || MediaKind.audio:
        return MediaTurnInput(
          withCaption(await _audio(message.id, attachment, size)),
        );
      case MediaKind.image
          when imageInput &&
              settings.imageInput &&
              visionMimes.contains(attachment.mime.toLowerCase()) &&
              attachment.size <= settings.imageMaxBytes:
        try {
          final bytes = await attachment.readBytes(
            maxBytes: settings.imageMaxBytes,
          );
          return MediaTurnInput(
            withCaption('[obrázek ${attachment.name}, $size]'),
            [HermesImage(mime: attachment.mime.toLowerCase(), bytes: bytes)],
          );
        } catch (e) {
          return MediaTurnInput(
            withCaption(_failedLine('obrázek ${attachment.name}, $size', e)),
          );
        }
      default:
        return MediaTurnInput(
          withCaption(await _savedFileLine(message.id, attachment, size)),
        );
    }
  }

  String _fileLine(BotAttachment a, String size, String? where) {
    final label = a.kind == MediaKind.image ? 'obrázek' : 'soubor';
    return '[$label: ${a.name}, $size, ${a.mime}${where == null ? '' : ', $where'}]';
  }

  Future<String> _savedFileLine(
    String messageId,
    BotAttachment a,
    String size,
  ) async {
    if (a.size > settings.maxFileBytes) {
      return _fileLine(
        a,
        size,
        'nestaženo: nad limit ${formatMediaSize(settings.maxFileBytes)}',
      );
    }
    try {
      final file = await save(messageId, a);
      return _fileLine(a, size, file.path);
    } catch (e) {
      return _fileLine(a, size, 'stažení selhalo: ${_reason(e)}');
    }
  }

  Future<String> _audio(String messageId, BotAttachment a, String size) async {
    final duration = a.duration;
    final what = a.kind == MediaKind.voice
        ? 'hlasová zpráva${duration == null ? '' : ' ${formatMediaDuration(duration.inMilliseconds)}'}'
        : 'zvuková nahrávka ${a.name}${duration == null ? '' : ' ${formatMediaDuration(duration.inMilliseconds)}'}';
    if (a.size > settings.maxFileBytes) {
      return '[$what, $size: nestaženo, nad limit '
          '${formatMediaSize(settings.maxFileBytes)}]';
    }
    final File file;
    try {
      file = await save(messageId, a);
    } catch (e) {
      return '[$what: stažení selhalo: ${_reason(e)}]';
    }
    final transcribe = this.transcribe;
    if (transcribe == null) {
      return '[$what: přepis není k dispozici, bridge nemá nastavený '
          '$missingSttKeyHint; soubor: ${file.path}]';
    }
    final tooLong = duration != null && duration > settings.sttMaxDuration;
    if (tooLong || a.size > settings.sttMaxBytes) {
      return '[$what, $size: příliš dlouhá na přepis (limit '
          '${settings.sttMaxDuration.inMinutes} min / '
          '${formatMediaSize(settings.sttMaxBytes)}); soubor: ${file.path}]';
    }
    try {
      final text = (await transcribe(file, mime: a.mime)).trim();
      return '[$what, přepis]: ${text.isEmpty ? '(bez řeči)' : text}';
    } catch (e) {
      log('Transcription of $messageId failed: $e');
      return '[$what: přepis selhal (${_reason(e)}); soubor: ${file.path}]';
    }
  }

  String _failedLine(String what, Object e) =>
      '[$what: stažení selhalo: ${_reason(e)}]';

  static String _reason(Object e) => switch (e) {
    BotMediaExpired() => 'platnost na serveru vypršela',
    BotMediaTooLarge() => 'nad limit',
    MediaTampered() || MediaHashMismatch() => 'soubor je poškozený',
    _ => _short(e.toString()),
  };

  static String _short(String text) =>
      text.length <= 160 ? text : '${text.substring(0, 157)}...';
}

/// ElevenLabs Speech-to-Text (`POST /v1/speech-to-text`, multipart, model
/// `scribe_v2` by default). The language is detected automatically.
class ElevenLabsTranscriber {
  ElevenLabsTranscriber({
    required this.apiKey,
    this.model = 'scribe_v2',
    String baseUrl = 'https://api.elevenlabs.io',
    this.timeout = const Duration(minutes: 3),
  }) : _base = Uri.parse(baseUrl.endsWith('/') ? baseUrl : '$baseUrl/');

  final String apiKey;
  final String model;
  final Duration timeout;
  final Uri _base;
  final _http = HttpClient();
  static final _random = Random.secure();

  Future<String> call(File audio, {required String mime}) async {
    final boundary =
        'jay-${List.generate(16, (_) => _random.nextInt(16).toRadixString(16)).join()}';
    String field(String name, String value) =>
        '--$boundary\r\nContent-Disposition: form-data; name="$name"\r\n\r\n'
        '$value\r\n';
    final head = utf8.encode(
      '${field('model_id', model)}${field('tag_audio_events', 'false')}'
      '--$boundary\r\nContent-Disposition: form-data; name="file"; '
      'filename="audio"\r\nContent-Type: $mime\r\n\r\n',
    );
    final tail = utf8.encode('\r\n--$boundary--\r\n');
    final length = await audio.length();
    final request = await _http
        .postUrl(_base.resolve('v1/speech-to-text'))
        .timeout(timeout);
    request.headers.set('xi-api-key', apiKey);
    request.headers.set(
      HttpHeaders.contentTypeHeader,
      'multipart/form-data; boundary=$boundary',
    );
    request.contentLength = head.length + length + tail.length;
    request.add(head);
    await request.addStream(audio.openRead());
    request.add(tail);
    final response = await request.close().timeout(timeout);
    final body = await utf8.decodeStream(response).timeout(timeout);
    if (response.statusCode != 200) {
      throw HttpException('ElevenLabs STT: HTTP ${response.statusCode}');
    }
    final json = jsonDecode(body);
    final text = json is Map ? json['text'] : null;
    if (text is! String) {
      throw const FormatException('ElevenLabs STT: no text in the answer');
    }
    return text;
  }

  void close() => _http.close(force: true);
}
