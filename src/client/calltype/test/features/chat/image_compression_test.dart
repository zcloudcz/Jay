import 'dart:math';
import 'dart:typed_data';

import 'package:calltype/features/chat/attachment.dart';
import 'package:calltype/features/chat/image_compression.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// A photo-like image: random noise compresses badly, so a large one is far
/// over the attachment limit even as a JPEG, like a real phone photo.
img.Image _noise(int width, int height, {int seed = 1}) {
  final random = Random(seed);
  final image = img.Image(width: width, height: height);
  for (final pixel in image) {
    pixel
      ..r = random.nextInt(256)
      ..g = random.nextInt(256)
      ..b = random.nextInt(256);
  }
  return image;
}

/// [image] as a JPEG carrying a GPS position, a camera model and an
/// orientation tag, as an iPhone writes them.
Uint8List _jpegWithExif(img.Image image, {int orientation = 1}) {
  image.exif.imageIfd['Model'] = img.IfdValueAscii('iPhone 15');
  image.exif.imageIfd.orientation = orientation;
  image.exif.gpsIfd['GPSLatitudeRef'] = img.IfdValueAscii('N');
  image.exif.gpsIfd['GPSLatitude'] = img.IfdValueRational(50, 1);
  return img.encodeJpg(image, quality: 100);
}

bool _isJpeg(Uint8List bytes) =>
    bytes.length > 3 &&
    bytes[0] == 0xFF &&
    bytes[1] == 0xD8 &&
    bytes[2] == 0xFF;

/// True when the bytes contain an APP1 "Exif" segment anywhere.
bool _containsExif(Uint8List bytes) {
  const marker = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]; // "Exif\0\0"
  outer:
  for (var i = 0; i + marker.length <= bytes.length; i++) {
    for (var j = 0; j < marker.length; j++) {
      if (bytes[i + j] != marker[j]) continue outer;
    }
    return true;
  }
  return false;
}

void main() {
  group('fitImageAsJpeg', () {
    test('a large photo is shrunk below the attachment limit', () {
      final input = _jpegWithExif(_noise(3000, 2000));
      expect(input.length, greaterThan(Attachment.maxBytes * 4));
      final fit = fitImageAsJpeg(input, maxBytes: Attachment.maxBytes);
      expect(fit.decoded, isTrue);
      final out = fit.bytes!;
      expect(out.length, lessThanOrEqualTo(Attachment.maxBytes));
      expect(_isJpeg(out), isTrue);
      final decoded = img.decodeJpg(out)!;
      // Aspect ratio kept (3:2), longest side within the picker cap.
      expect(decoded.width, lessThanOrEqualTo(2048));
      expect(decoded.width / decoded.height, closeTo(1.5, 0.01));
      // The result is a valid attachment.
      expect(() => Attachment(name: 'IMG.jpg', bytes: out), returnsNormally);
    });

    test('EXIF with GPS and camera model is gone from the output', () {
      final input = _jpegWithExif(_noise(400, 300));
      expect(_containsExif(input), isTrue);
      expect(img.decodeJpg(input)!.exif.gpsIfd.isEmpty, isFalse);
      final out = fitImageAsJpeg(input, maxBytes: Attachment.maxBytes).bytes!;
      expect(_containsExif(out), isFalse);
      expect(img.decodeJpg(out)!.exif.isEmpty, isTrue);
    });

    test('EXIF orientation is applied to the pixels before it is dropped', () {
      // Orientation 6 = rotate 90° clockwise to display: a 400x300 stored
      // image is shown as 300x400.
      final input = _jpegWithExif(_noise(400, 300), orientation: 6);
      final out = fitImageAsJpeg(input, maxBytes: Attachment.maxBytes).bytes!;
      final decoded = img.decodeJpg(out)!;
      expect((decoded.width, decoded.height), (300, 400));
    });

    test('a small image keeps its size and is re-encoded as JPEG', () {
      final png = img.encodePng(_noise(120, 80));
      final out = fitImageAsJpeg(png, maxBytes: Attachment.maxBytes).bytes!;
      expect(_isJpeg(out), isTrue);
      final decoded = img.decodeJpg(out)!;
      expect((decoded.width, decoded.height), (120, 80));
      // Deterministic: the same input gives the same bytes.
      expect(fitImageAsJpeg(png, maxBytes: Attachment.maxBytes).bytes, out);
    });

    test('transparency becomes white, not black', () {
      final image = img.Image(width: 10, height: 10, numChannels: 4)
        ..clear(img.ColorRgba8(0, 0, 0, 0));
      final out = fitImageAsJpeg(
        img.encodePng(image),
        maxBytes: Attachment.maxBytes,
      ).bytes!;
      final pixel = img.decodeJpg(out)!.getPixel(5, 5);
      expect(pixel.r, greaterThan(240));
    });

    test('bytes that are not an image report decoded: false', () {
      final fit = fitImageAsJpeg(
        Uint8List.fromList(List.filled(100, 7)),
        maxBytes: Attachment.maxBytes,
      );
      expect(fit.bytes, isNull);
      expect(fit.decoded, isFalse);
    });

    test('an impossible limit reports decoded: true without bytes', () {
      final fit = fitImageAsJpeg(
        img.encodePng(_noise(200, 200)),
        maxBytes: 100,
      );
      expect(fit.bytes, isNull);
      expect(fit.decoded, isTrue);
    });

    test(
      'prepareImageAttachment runs the same conversion off the UI isolate',
      () async {
        final input = _jpegWithExif(_noise(1600, 1200));
        final fit = await prepareImageAttachment(
          input,
          maxBytes: Attachment.maxBytes,
        );
        expect(fit.bytes!.length, lessThanOrEqualTo(Attachment.maxBytes));
        expect(_containsExif(fit.bytes!), isFalse);
      },
    );
  });

  group('names', () {
    test('image extensions are recognised case-insensitively', () {
      for (final name in ['a.jpg', 'b.JPEG', 'c.png', 'd.gif', 'e.WebP']) {
        expect(isImageAttachmentName(name), isTrue, reason: name);
      }
      for (final name in ['notes.txt', 'jpg', 'photo.', 'x.heic', 'a.pdf']) {
        expect(isImageAttachmentName(name), isFalse, reason: name);
      }
    });

    test('photo names are IMG_<timestamp>.jpg, numbered after the first', () {
      final t = DateTime(2026, 11, 6, 9, 5, 3);
      expect(photoAttachmentName(t), 'IMG_20261106_090503.jpg');
      expect(photoAttachmentName(t, index: 1), 'IMG_20261106_090503_2.jpg');
      expect(
        () => Attachment(name: photoAttachmentName(t), bytes: Uint8List(1)),
        returnsNormally,
      );
    });
  });
}
