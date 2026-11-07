import 'dart:io';

import 'package:fc_native_video_thumbnail/fc_native_video_thumbnail.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import 'media_device.dart';
import 'media_thumbnail.dart';

/// Android's save dialog (Storage Access Framework) hands back a content
/// URI dart:io cannot write to, so file_picker needs the bytes in memory.
/// Above this the share sheet takes the file by path instead ("Save to
/// Files" / Drive), never a huge buffer.
const _androidSaveInMemoryLimit = 100 * 1024 * 1024;

Future<VideoProbe> probeVideo(String path) async {
  int? durationMs;
  int? width;
  int? height;
  Uint8List? thumbnail;
  // video_player exists only on Android, iOS and macOS (contract M14); it
  // reads duration and size from the container without decoding frames.
  if (const {
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.macOS,
  }.contains(defaultTargetPlatform)) {
    final controller = VideoPlayerController.file(File(path));
    try {
      await controller.initialize().timeout(const Duration(seconds: 10));
      durationMs = controller.value.duration.inMilliseconds;
      final size = controller.value.size;
      if (size.width > 0 && size.height > 0) {
        width = size.width.round();
        height = size.height.round();
      }
    } catch (_) {
      // Unknown codec / container: send without duration.
    } finally {
      await controller.dispose();
    }
  }
  try {
    final frame = await FcNativeVideoThumbnail().saveThumbnailToBytes(
      srcFile: path,
      width: mediaThumbnailSide,
      height: mediaThumbnailSide,
      quality: 70,
    );
    if (frame != null) {
      thumbnail = (await prepareMediaThumbnail(frame)).thumbnail;
    }
  } catch (_) {
    // No thumbnail is fine (spec Limits).
  }
  return VideoProbe(
    durationMs: durationMs,
    width: width,
    height: height,
    thumbnail: thumbnail,
  );
}

Future<SaveOutcome> saveWithDialog({
  required String name,
  required String mime,
  required String path,
}) async {
  final file = File(path);
  if (defaultTargetPlatform == TargetPlatform.android) {
    if (await file.length() > _androidSaveInMemoryLimit) {
      return SaveOutcome.cancelled;
    }
    final uri = await FilePicker.saveFile(
      fileName: name,
      bytes: await file.readAsBytes(),
      mimeType: mime,
    );
    return uri == null ? SaveOutcome.cancelled : SaveOutcome.file;
  }
  // Desktop: the plugin writes the bytes we pass to the chosen path; pass
  // none and stream the file there ourselves (a video may be gigabytes).
  final uri = await FilePicker.saveFile(
    fileName: name,
    bytes: Uint8List(0),
    mimeType: mime,
  );
  if (uri == null) return SaveOutcome.cancelled;
  if (uri.scheme != 'file') throw StateError('unexpected save target');
  final target = File(uri.toFilePath());
  final sink = target.openWrite();
  try {
    await sink.addStream(file.openRead());
  } finally {
    await sink.close();
  }
  return SaveOutcome.file;
}

/// Whether [saveWithDialog] would refuse (Android, too large to buffer):
/// the caller then offers the share sheet.
Future<bool> needsShareToSave(String path) async =>
    defaultTargetPlatform == TargetPlatform.android &&
    await File(path).length() > _androidSaveInMemoryLimit;

Future<void> deleteTempFile(String path) async {
  final file = File(path);
  if (await file.exists()) await file.delete();
}

/// Only web needs object URLs; on io players take the file path.
String? objectUrlFor(Uint8List bytes, String mime) => null;

/// In-app player for a stored video (Android, iOS, macOS).
VideoPlayerController videoControllerFor({
  String? path,
  Uint8List? bytes,
  required String mime,
}) => VideoPlayerController.file(File(path!));
