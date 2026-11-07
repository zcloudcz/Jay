import 'dart:async';

import 'package:image_picker/image_picker.dart' show XFile;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../chat/attachment_media.dart';
import 'media_device_io.dart'
    if (dart.library.js_interop) 'media_device_web.dart'
    as platform;

/// A finished recording, ready for ChatController.sendMedia.
class RecordedVoice {
  const RecordedVoice({required this.file, required this.mime, this.cleanup});
  final PickedMedia file;
  final String mime;

  /// Deletes the recorder's temp file once the media store has its copy.
  final Future<void> Function()? cleanup;
}

/// The microphone behind a seam (contract 4.2) so widget tests drive the
/// voice UI with a fake. [create] is replaced in tests.
abstract class VoiceRecorder {
  static VoiceRecorder Function() create = PluginVoiceRecorder.new;

  /// Asks for (or checks) the microphone permission.
  Future<bool> hasPermission();
  Future<void> start();

  /// Input level samples, 0 (silence) .. 1 (loud), about every 100 ms
  /// while recording; the waveform is built from them.
  Stream<double> get levels;

  /// Stops and returns the recording (null if nothing was recorded).
  Future<RecordedVoice?> stop();

  /// Stops and throws the recording away.
  Future<void> cancel();
  Future<void> dispose();
}

/// [VoiceRecorder] on the `record` plugin: AAC-LC in `.m4a` where the
/// platform encodes it (iOS, Android, macOS, Windows), otherwise what the
/// browser offers (Opus in WebM on Chrome / Firefox), labelled truthfully.
class PluginVoiceRecorder implements VoiceRecorder {
  final _recorder = AudioRecorder();
  String _mime = 'audio/mp4';
  String _extension = 'm4a';

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<void> start() async {
    var encoder = AudioEncoder.aacLc;
    if (!await _recorder.isEncoderSupported(AudioEncoder.aacLc)) {
      encoder = await _recorder.isEncoderSupported(AudioEncoder.opus)
          ? AudioEncoder.opus
          : AudioEncoder.wav;
    }
    final (mime, extension) = switch (encoder) {
      AudioEncoder.opus =>
        kIsWeb ? ('audio/webm', 'webm') : ('audio/ogg', 'ogg'),
      AudioEncoder.wav => ('audio/wav', 'wav'),
      _ => ('audio/mp4', 'm4a'),
    };
    _mime = mime;
    _extension = extension;
    final stamp = DateTime.now().millisecondsSinceEpoch;
    // Web ignores the path and returns a blob URL from stop().
    final path = kIsWeb
        ? ''
        : '${(await getTemporaryDirectory()).path}/voice-$stamp.$_extension';
    await _recorder.start(
      RecordConfig(encoder: encoder, numChannels: 1),
      path: path,
    );
  }

  @override
  Stream<double> get levels => _recorder
      .onAmplitudeChanged(const Duration(milliseconds: 100))
      // dBFS: about -50 is room noise, 0 the loudest the input takes.
      .map((a) => ((a.current + 50) / 50).clamp(0.0, 1.0).toDouble());

  @override
  Future<RecordedVoice?> stop() async {
    final path = await _recorder.stop();
    if (path == null) return null;
    final file = XFile(path, mimeType: _mime);
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final name =
        'voice-${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}.$_extension';
    return RecordedVoice(
      file: PickedMedia(
        name: name,
        length: file.length,
        read: file.readAsBytes,
        openRead: file.openRead,
        mimeType: _mime,
      ),
      mime: _mime,
      cleanup: kIsWeb ? null : () => _deleteTemp(path),
    );
  }

  static Future<void> _deleteTemp(String path) async {
    try {
      await platform.deleteTempFile(path);
    } catch (_) {}
  }

  @override
  Future<void> cancel() async {
    await _recorder.cancel();
  }

  @override
  Future<void> dispose() => _recorder.dispose();
}
