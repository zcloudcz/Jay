import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../chat/attachment_media.dart';
import 'media_device_io.dart'
    if (dart.library.js_interop) 'media_device_web.dart'
    as platform;

/// What a video probe found out; every field is optional.
class VideoProbe {
  const VideoProbe({this.durationMs, this.width, this.height, this.thumbnail});
  final int? durationMs;
  final int? width;
  final int? height;

  /// JPEG, at most 24 KiB and 320 px on the longest side (contract 3).
  final Uint8List? thumbnail;
}

/// Where the platform put a saved file.
enum SaveOutcome { gallery, file, shared, cancelled }

/// Platform pickers, players and save targets for the encrypted media path,
/// behind one seam (like [AttachmentMedia]) so widget tests run without
/// platform channels. Replaced in tests through [instance].
abstract class MediaDevice {
  static MediaDevice instance = PluginMediaDevice();

  /// iOS / Android: camera and photo library; elsewhere file dialogs.
  bool get isMobile;

  /// Windows / Linux have no maintained video_player implementation: the
  /// video opens in the system player instead (contract M14).
  bool get inAppVideo;

  Future<PickedMedia?> pickVideo({required bool camera});

  /// Any file, or only audio files; streamed, never read at once.
  Future<PickedMedia?> pickFile({bool audioOnly = false});

  /// Duration, size and a small thumbnail of a stored video, as far as the
  /// platform can tell (null fields otherwise).
  Future<VideoProbe> probeVideo(String path);

  /// "Save to device" (contract M10) from a stored file at [path] (mobile /
  /// desktop) or from [bytes] (web, session memory).
  Future<SaveOutcome> save({
    required String name,
    required String mime,
    required bool toGallery,
    String? path,
    Uint8List? bytes,
    Rect? origin,
  });

  /// Opens a stored file with the system app (files, and video on Windows
  /// / Linux). Returns false when nothing could open it.
  Future<bool> open(String path);
}

/// Real implementation on image_picker, file_picker, gal, share_plus and
/// url_launcher; the dart:io parts live in media_device_io.dart.
class PluginMediaDevice implements MediaDevice {
  final _picker = ImagePicker();

  @override
  bool get isMobile => AttachmentMedia.isMobile;

  @override
  bool get inAppVideo =>
      kIsWeb ||
      const {
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
      }.contains(defaultTargetPlatform);

  PickedMedia _fromXFile(XFile file) => PickedMedia(
    name: file.name,
    length: file.length,
    read: file.readAsBytes,
    openRead: file.openRead,
    mimeType: file.mimeType,
    path: kIsWeb ? null : file.path,
  );

  @override
  Future<PickedMedia?> pickVideo({required bool camera}) async {
    if (!isMobile) {
      final file = await FilePicker.pickFile(type: FileType.video);
      return file == null ? null : _fromPlatformFile(file);
    }
    final file = await _picker.pickVideo(
      source: camera ? ImageSource.camera : ImageSource.gallery,
    );
    return file == null ? null : _fromXFile(file);
  }

  PickedMedia _fromPlatformFile(PlatformFile file) => PickedMedia(
    name: file.name,
    length: file.length,
    read: file.readAsBytes,
    openRead: file.readAsByteStream,
    path: kIsWeb ? null : file.path,
  );

  @override
  Future<PickedMedia?> pickFile({bool audioOnly = false}) async {
    final file = await FilePicker.pickFile(
      type: audioOnly ? FileType.audio : FileType.any,
    );
    return file == null ? null : _fromPlatformFile(file);
  }

  @override
  Future<VideoProbe> probeVideo(String path) => platform.probeVideo(path);

  @override
  Future<SaveOutcome> save({
    required String name,
    required String mime,
    required bool toGallery,
    String? path,
    Uint8List? bytes,
    Rect? origin,
  }) async {
    if (toGallery && isMobile && path != null) {
      if (!await Gal.hasAccess() && !await Gal.requestAccess()) {
        throw const GalleryAccessDenied();
      }
      if (mime.startsWith('video/')) {
        await Gal.putVideo(path);
      } else {
        await Gal.putImage(path);
      }
      return SaveOutcome.gallery;
    }
    if (kIsWeb) {
      // The browser's own download (file_picker's web saveFile).
      await FilePicker.saveFile(fileName: name, bytes: bytes!, mimeType: mime);
      return SaveOutcome.file;
    }
    if (defaultTargetPlatform == TargetPlatform.iOS ||
        await platform.needsShareToSave(path!)) {
      // iOS has no save dialog: the share sheet's "Save to Files". Same for
      // a huge file on Android (see media_device_io.dart).
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(path!, name: name, mimeType: mime)],
          fileNameOverrides: [name],
          sharePositionOrigin: origin,
        ),
      );
      return result.status == ShareResultStatus.dismissed
          ? SaveOutcome.cancelled
          : SaveOutcome.shared;
    }
    return platform.saveWithDialog(name: name, mime: mime, path: path);
  }

  @override
  Future<bool> open(String path) async {
    if (isMobile) {
      // No "open with" without another plugin: the share sheet lists the
      // apps that can take the file.
      final result = await SharePlus.instance.share(
        ShareParams(files: [XFile(path)]),
      );
      return result.status != ShareResultStatus.unavailable;
    }
    return launchUrl(Uri.file(path));
  }
}
