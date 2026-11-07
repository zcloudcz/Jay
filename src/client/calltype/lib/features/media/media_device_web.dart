import 'dart:js_interop';
import 'dart:typed_data';

import 'package:video_player/video_player.dart';
import 'package:web/web.dart' as web;

import 'media_device.dart';

/// Web: no file paths; the browser cannot probe a picked video cheaply.
Future<VideoProbe> probeVideo(String path) async => const VideoProbe();

Future<SaveOutcome> saveWithDialog({
  required String name,
  required String mime,
  required String path,
}) => throw UnsupportedError('no file paths on web');

Future<bool> needsShareToSave(String path) async => false;

Future<void> deleteTempFile(String path) async {}

/// A `blob:` URL for session media (video_player on web plays URLs only).
/// Lives until the page is closed, like the media itself (contract M13).
String? objectUrlFor(Uint8List bytes, String mime) => web.URL.createObjectURL(
  web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mime)),
);

/// In-app player for session media: a blob URL of the decrypted bytes.
VideoPlayerController videoControllerFor({
  String? path,
  Uint8List? bytes,
  required String mime,
}) => VideoPlayerController.networkUrl(Uri.parse(objectUrlFor(bytes!, mime)!));
