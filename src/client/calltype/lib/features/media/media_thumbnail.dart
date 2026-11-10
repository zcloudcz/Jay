import 'package:calltype_core/media/media_info.dart'
    show mediaThumbnailMaxBytes, mediaThumbnailSide;
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

export 'package:calltype_core/media/media_info.dart'
    show jpegDimensions, mediaThumbnailMaxBytes, mediaThumbnailSide;

typedef MediaThumbnail = ({Uint8List? thumbnail, int? width, int? height});

/// A JPEG of at most 320 px / 24 KiB from an image (or a video frame), plus
/// the source dimensions. It travels inside the encrypted message so the
/// receiver sees a preview BEFORE choosing to download (M8). Re-encoding
/// also drops EXIF, like the inline photo path.
MediaThumbnail makeMediaThumbnail(Uint8List input) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(input);
  } catch (_) {
    decoded = null;
  }
  if (decoded == null) return (thumbnail: null, width: null, height: null);
  final oriented = img.bakeOrientation(decoded);
  final width = oriented.width;
  final height = oriented.height;
  var side = mediaThumbnailSide;
  while (side >= 80) {
    final scaled = img.copyResize(
      oriented,
      width: width >= height ? (width > side ? side : width) : null,
      height: width >= height ? null : (height > side ? side : height),
      interpolation: img.Interpolation.average,
    )..exif = img.ExifData();
    for (final quality in const [70, 55, 40]) {
      final out = img.encodeJpg(scaled, quality: quality);
      if (out.length <= mediaThumbnailMaxBytes) {
        return (thumbnail: out, width: width, height: height);
      }
    }
    side = (side * 0.75).floor();
  }
  return (thumbnail: null, width: width, height: height);
}

/// [makeMediaThumbnail] off the UI isolate (inline on web, see
/// prepareImageAttachment for why `compute`).
Future<MediaThumbnail> prepareMediaThumbnail(Uint8List input) =>
    compute(makeMediaThumbnail, input);
