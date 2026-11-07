import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:calltype_core/media/media_info.dart';

/// Optional ffmpeg / ffprobe helpers for outgoing media: voice conversion to
/// the format every Jay client plays, duration, waveform and thumbnails.
///
/// Everything here is best effort: without the binaries (or when a call
/// fails) the file is sent as it is, without the optional metadata.
class BotMediaTools {
  BotMediaTools({String? ffmpeg, String? ffprobe})
    : ffmpeg = ffmpeg ?? 'ffmpeg',
      ffprobe = ffprobe ?? _sibling(ffmpeg, 'ffprobe') ?? 'ffprobe';

  /// No ffmpeg at all: files are sent unchanged, no waveform or thumbnail.
  BotMediaTools.disabled() : ffmpeg = '', ffprobe = '', _available = false;

  final String ffmpeg;
  final String ffprobe;
  bool? _available;

  static String? _sibling(String? path, String name) {
    if (path == null || !path.contains('/')) return null;
    return '${path.substring(0, path.lastIndexOf('/'))}/$name';
  }

  /// Whether ffmpeg runs (checked once).
  Future<bool> get available async =>
      _available ??= await _runs(ffmpeg, ['-hide_banner', '-version']);

  static Future<bool> _runs(String exe, List<String> args) async {
    if (exe.isEmpty) return false;
    try {
      final r = await Process.run(
        exe,
        args,
      ).timeout(const Duration(seconds: 10));
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Converts [input] to the app's voice format: AAC-LC, mono, 44.1 kHz, in
  /// an `.m4a` (MP4) container with the index up front. That is what the app
  /// records on iOS, Android, macOS and Windows and what `audioplayers` plays
  /// on every platform including web. Throws when ffmpeg fails.
  Future<File> toVoiceM4a(File input, String outPath) async {
    final r = await Process.run(ffmpeg, [
      '-nostdin', '-hide_banner', '-loglevel', 'error', '-y', //
      '-i', input.path,
      '-vn', '-map_metadata', '-1',
      '-ac', '1', '-ar', '44100', '-c:a', 'aac', '-b:a', '64k',
      '-movflags', '+faststart',
      '-f', 'mp4', outPath,
    ]).timeout(const Duration(minutes: 5));
    if (r.exitCode != 0) {
      throw ProcessException(
        ffmpeg,
        const [],
        _short('${r.stderr}'),
        r.exitCode,
      );
    }
    return File(outPath);
  }

  /// Duration and a 64-bar waveform (0..255, the app's scale: dBFS -50..0)
  /// from decoding [audio] to 8 kHz mono PCM; null when ffmpeg is missing
  /// or fails. Streams, so long files cost time, not memory.
  Future<({int durationMs, Uint8List waveform})?> analyzeAudio(
    File audio,
  ) async {
    if (!await available) return null;
    try {
      final process = await Process.start(ffmpeg, [
        '-nostdin', '-hide_banner', '-loglevel', 'error', //
        '-i', audio.path, '-vn', '-ac', '1', '-ar', '8000',
        '-f', 's16le', '-',
      ]);
      unawaited(process.stderr.drain<void>());
      const window = 800; // 100 ms, like the app's amplitude stream
      final levels = <double>[];
      var samples = 0;
      var peak = 0;
      var inWindow = 0;
      int? low;
      await for (final chunk in process.stdout.timeout(
        const Duration(minutes: 2),
      )) {
        for (final byte in chunk) {
          if (low == null) {
            low = byte;
            continue;
          }
          var value = (byte << 8) | low;
          low = null;
          if (value >= 0x8000) value -= 0x10000;
          final magnitude = value.abs();
          if (magnitude > peak) peak = magnitude;
          samples++;
          if (++inWindow == window) {
            levels.add(_level(peak));
            peak = 0;
            inWindow = 0;
          }
        }
      }
      if (inWindow > 0) levels.add(_level(peak));
      if (await process.exitCode != 0 || samples == 0) return null;
      return (
        durationMs: samples * 1000 ~/ 8000,
        waveform: reduceWaveform(levels),
      );
    } catch (_) {
      return null;
    }
  }

  static double _level(int peak) {
    if (peak <= 0) return 0;
    final db = 20 * log(peak / 32768) / ln10;
    return ((db + 50) / 50).clamp(0.0, 1.0);
  }

  /// Width, height and duration from ffprobe; null when unavailable.
  Future<({int? width, int? height, int? durationMs})?> probe(File f) async {
    if (!await available) return null;
    try {
      final r = await Process.run(ffprobe, [
        '-v',
        'error',
        '-show_entries',
        'stream=codec_type,width,height:format=duration',
        '-of',
        'json',
        f.path,
      ]).timeout(const Duration(seconds: 30));
      if (r.exitCode != 0) return null;
      final json = jsonDecode('${r.stdout}');
      if (json is! Map) return null;
      int? width;
      int? height;
      for (final s in (json['streams'] as List? ?? const [])) {
        if (s is Map && s['codec_type'] == 'video' && s['width'] is int) {
          width = s['width'] as int;
          height = s['height'] as int?;
          break;
        }
      }
      final seconds = double.tryParse(
        '${(json['format'] as Map?)?['duration'] ?? ''}',
      );
      return (
        width: width != null && width > 0 ? width : null,
        height: height != null && height > 0 ? height : null,
        durationMs: seconds == null || seconds < 0
            ? null
            : (seconds * 1000).round(),
      );
    } catch (_) {
      return null;
    }
  }

  /// A JPEG thumbnail of the first frame of an image or video: longest side
  /// at most 320 px and at most 24 KiB (contract section 3), or null.
  Future<Uint8List?> thumbnail(File f) async {
    if (!await available) return null;
    for (final quality in const [5, 10, 18, 31]) {
      try {
        final process = await Process.start(ffmpeg, [
          '-nostdin', '-hide_banner', '-loglevel', 'error', //
          '-i', f.path, '-frames:v', '1',
          '-vf',
          "scale='min($mediaThumbnailSide,iw)':'min($mediaThumbnailSide,ih)'"
              ':force_original_aspect_ratio=decrease',
          '-c:v', 'mjpeg', '-q:v', '$quality', '-f', 'image2pipe', '-',
        ]);
        unawaited(process.stderr.drain<void>());
        final out = BytesBuilder(copy: false);
        var tooBig = false;
        await for (final chunk in process.stdout.timeout(
          const Duration(seconds: 60),
        )) {
          out.add(chunk);
          if (out.length > 4 * mediaThumbnailMaxBytes) {
            tooBig = true;
            break;
          }
        }
        if (tooBig) {
          process.kill();
          await process.exitCode;
          continue;
        }
        if (await process.exitCode != 0) return null;
        final bytes = out.toBytes();
        final dims = jpegDimensions(bytes);
        if (dims == null ||
            dims.width > mediaThumbnailSide ||
            dims.height > mediaThumbnailSide) {
          return null;
        }
        if (bytes.length <= mediaThumbnailMaxBytes) return bytes;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  static String _short(String text) {
    final t = text.trim();
    return t.length <= 300 ? t : '${t.substring(0, 297)}...';
  }
}
