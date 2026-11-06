import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Extensions treated as images when a received attachment is rendered.
/// The name is only a hint: the bubble still falls back to the download
/// button when the bytes do not decode (see `ImageAttachmentThumbnail`).
const _imageExtensions = {'jpg', 'jpeg', 'png', 'gif', 'webp'};

/// True when [name] looks like an image the bubble can show inline.
bool isImageAttachmentName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return false;
  return _imageExtensions.contains(name.substring(dot + 1).toLowerCase());
}

/// `IMG_20261106_143005.jpg`; [index] > 0 adds `_2`, `_3`, ... so several
/// photos picked in the same second keep distinct names in the chat.
String photoAttachmentName(DateTime time, {int index = 0}) {
  String two(int v) => v.toString().padLeft(2, '0');
  final stamp =
      '${time.year}${two(time.month)}${two(time.day)}_'
      '${two(time.hour)}${two(time.minute)}${two(time.second)}';
  return index > 0 ? 'IMG_${stamp}_${index + 1}.jpg' : 'IMG_$stamp.jpg';
}

/// Outcome of [fitImageAsJpeg]: [bytes] is the JPEG, or null with
/// [decoded] telling "not an image we can read" from "still too large".
typedef ImageFit = ({Uint8List? bytes, bool decoded});

/// Longest side, in pixels, of the first attempt. Matches what
/// image_picker is asked for, so a picked photo is not shrunk twice.
const _firstMaxSide = 2048;

/// Below this the photo is no longer worth sending; give up instead.
const _minSide = 240;

/// JPEG qualities tried for every size before the next smaller size.
const _qualities = [85, 70, 55];

/// Re-encodes [input] (any format package:image reads: JPEG, PNG, GIF,
/// WebP, BMP, TIFF) as a baseline JPEG of at most [maxBytes], shrinking
/// first the quality and then the size.
///
/// The image is ALWAYS re-encoded, even when it already fits: the encoder
/// writes no EXIF, so GPS position, camera serial and capture time never
/// leave the device inside an attachment or a public channel post (privacy;
/// image_picker on iOS copies the original metadata into its output). The
/// EXIF orientation is baked into the pixels first so the photo is not shown
/// sideways once the tag is gone. Transparent areas become white because
/// JPEG has no alpha channel. An animated GIF keeps only its first frame.
///
/// Synchronous and CPU heavy: call [prepareImageAttachment] from UI code.
ImageFit fitImageAsJpeg(Uint8List input, {required int maxBytes}) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(input);
  } catch (_) {
    // A corrupt file can throw instead of returning null; same outcome.
    decoded = null;
  }
  if (decoded == null) return (bytes: null, decoded: false);
  var base = img.bakeOrientation(
    decoded.numFrames > 1
        ? img.Image.from(decoded.frames.first, noAnimation: true)
        : decoded,
  );
  base = _flatten(base);
  final longest = base.width > base.height ? base.width : base.height;
  var side = longest < _firstMaxSide ? longest : _firstMaxSide;
  // The first round always runs, even for a tiny image, to strip metadata.
  for (var first = true; first || side >= _minSide; first = false) {
    final scaled = longest > side
        ? img.copyResize(
            base,
            width: base.width >= base.height ? side : null,
            height: base.width >= base.height ? null : side,
            interpolation: img.Interpolation.average,
          )
        : img.Image.from(base);
    // copyResize and Image.from copy the EXIF block; clear it on the very
    // object that gets encoded.
    scaled.exif = img.ExifData();
    var smallest = 0;
    for (final quality in _qualities) {
      final out = img.encodeJpg(scaled, quality: quality);
      if (out.length <= maxBytes) return (bytes: out, decoded: true);
      smallest = out.length;
    }
    // JPEG size grows roughly with the pixel count, so the next side is
    // estimated from the last attempt instead of walking a fixed ladder:
    // pure-Dart encodes are slow and a phone photo should need two rounds,
    // not eight. At least 20 % smaller each round so the loop always ends.
    final estimate = (side * sqrt(maxBytes / smallest) * 0.95).floor();
    final shrunk = (side * 0.8).floor();
    side = estimate < shrunk ? estimate : shrunk;
  }
  return (bytes: null, decoded: true);
}

/// Composites an image with alpha onto white; JPEG would otherwise turn
/// transparent pixels black.
img.Image _flatten(img.Image image) {
  if (!image.hasAlpha) return image;
  final background = img.Image(width: image.width, height: image.height)
    ..clear(img.ColorRgb8(255, 255, 255));
  return img.compositeImage(background, image.convert(numChannels: 4));
}

typedef _FitRequest = ({Uint8List input, int maxBytes});

ImageFit _fitEntry(_FitRequest request) =>
    fitImageAsJpeg(request.input, maxBytes: request.maxBytes);

/// [fitImageAsJpeg] off the UI isolate. `compute` instead of `Isolate.run`
/// because dart:isolate does not exist on web; there `compute` runs inline,
/// which is acceptable because image_picker / the browser already capped the
/// input size and the progress dialog is on screen first.
Future<ImageFit> prepareImageAttachment(
  Uint8List input, {
  required int maxBytes,
}) => compute(_fitEntry, (input: input, maxBytes: maxBytes));
