import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import 'attachment_media.dart';
import 'image_compression.dart';

/// Where the next attachment comes from.
enum AttachSource {
  /// iOS / Android system photo picker (several photos at once).
  photoLibrary,

  /// iOS / Android camera, only where image_picker supports it.
  camera,

  /// Web / desktop: a file dialog filtered to images.
  photo,

  /// Any file through the document picker (on iOS: the Files app).
  file,
}

/// Bottom sheet with the attachment sources of this platform. A separate
/// photo entry exists because the document picker that "File" opens is the
/// Files app on iOS and cannot reach the photo library at all.
Future<AttachSource?> showAttachSourceSheet(BuildContext context) {
  final mobile = AttachmentMedia.isMobile;
  final camera = mobile && AttachmentMedia.instance.supportsCamera;
  return showModalBottomSheet<AttachSource>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      final l10n = sheetContext.l10n;
      Widget tile(AttachSource source, IconData icon, String label) => ListTile(
        key: ValueKey('attach-${source.name}'),
        leading: Icon(icon),
        title: Text(label),
        onTap: () => Navigator.of(sheetContext).pop(source),
      );
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (mobile)
              tile(
                AttachSource.photoLibrary,
                Icons.photo_library_outlined,
                l10n.chatAttachPhotoLibrary,
              )
            else
              tile(
                AttachSource.photo,
                Icons.image_outlined,
                l10n.chatAttachPhoto,
              ),
            if (camera)
              tile(
                AttachSource.camera,
                Icons.photo_camera_outlined,
                l10n.chatAttachCamera,
              ),
            tile(
              AttachSource.file,
              Icons.insert_drive_file_outlined,
              l10n.chatAttachFile,
            ),
          ],
        ),
      );
    },
  );
}

/// One picked photo after conversion: [bytes] is null when it could not be
/// read ([decoded] false) or not made small enough ([decoded] true).
class PreparedPhoto {
  const PreparedPhoto({
    required this.name,
    required this.bytes,
    required this.decoded,
  });
  final String name;
  final Uint8List? bytes;
  final bool decoded;
}

/// Converts [photos] to JPEGs of at most [maxBytes] (see [fitImageAsJpeg])
/// while a modal progress dialog is shown; the work itself runs off the UI
/// isolate. Names are `IMG_<timestamp>.jpg` because the content is always
/// a fresh JPEG, whatever the picker called the original (HEIC included).
Future<List<PreparedPhoto>> preparePhotos(
  BuildContext context,
  List<PickedMedia> photos, {
  required int maxBytes,
}) async {
  final progress = ValueNotifier<int>(1);
  final navigator = Navigator.of(context, rootNavigator: true);
  // A route object of our own, removed by identity afterwards: popping
  // "whatever is on top" could close something else the user opened.
  final route = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 20),
            Expanded(
              child: ValueListenableBuilder<int>(
                valueListenable: progress,
                builder: (context, current, _) => Text(
                  context.l10n.chatPhotoPreparing(current, photos.length),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  navigator.push(route);
  final now = DateTime.now();
  final results = <PreparedPhoto>[];
  try {
    for (var i = 0; i < photos.length; i++) {
      progress.value = i + 1;
      final name = photoAttachmentName(now, index: i);
      try {
        final fit = await prepareImageAttachment(
          await photos[i].readAsBytes(),
          maxBytes: maxBytes,
        );
        results.add(
          PreparedPhoto(name: name, bytes: fit.bytes, decoded: fit.decoded),
        );
      } catch (_) {
        results.add(PreparedPhoto(name: name, bytes: null, decoded: false));
      }
    }
  } finally {
    if (route.isActive) navigator.removeRoute(route);
    // The dialog unmounts during the next frame; disposing earlier would
    // pull the notifier out from under its last listener.
    WidgetsBinding.instance.addPostFrameCallback((_) => progress.dispose());
  }
  return results;
}
