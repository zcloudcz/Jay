import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Longest side of a `thumbnail` (contract section 3).
const mediaThumbnailSide = 320;

/// Largest decoded `thumbnail` (contract section 3).
const mediaThumbnailMaxBytes = 24 * 1024;

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

/// Width and height from the frame header of a baseline or progressive
/// JPEG, or null when [bytes] is not a JPEG with a readable frame header.
///
/// WHY: a received thumbnail is sender-controlled and rendered before any
/// download tap. Only 24 KiB small, a PNG or WebP can still declare a huge
/// canvas that decodes to gigabytes; a JPEG whose header says at most
/// [mediaThumbnailSide] px cannot.
({int width, int height})? jpegDimensions(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return null;
  var i = 2;
  while (i + 3 < bytes.length) {
    if (bytes[i] != 0xFF) return null;
    final marker = bytes[i + 1];
    if (marker == 0xFF) {
      i++; // fill byte
      continue;
    }
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      i += 2; // no length
      continue;
    }
    if (marker == 0xD9 || marker == 0xDA) return null; // no frame header
    final length = (bytes[i + 2] << 8) | bytes[i + 3];
    if (length < 2) return null;
    final isFrame =
        marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (isFrame) {
      if (i + 8 >= bytes.length) return null;
      final height = (bytes[i + 5] << 8) | bytes[i + 6];
      final width = (bytes[i + 7] << 8) | bytes[i + 8];
      return (width: width, height: height);
    }
    i += 2 + length;
  }
  return null;
}

/// [makeMediaThumbnail] off the UI isolate (inline on web, see
/// prepareImageAttachment for why `compute`).
Future<MediaThumbnail> prepareMediaThumbnail(Uint8List input) =>
    compute(makeMediaThumbnail, input);
