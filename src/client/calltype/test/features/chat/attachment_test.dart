import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:calltype/features/chat/attachment.dart';

void main() {
  test('attachment bytes and unicode name survive encoding', () {
    final original = Attachment(
      name: 'fotka-č.png',
      bytes: Uint8List.fromList([0, 255, 1]),
    );
    final restored = Attachment.decode(original.encode());
    expect(restored.name, original.name);
    expect(restored.bytes, original.bytes);
  });
  test('attachment at exactly the size limit is accepted', () {
    final attachment = Attachment(
      name: 'max.bin',
      bytes: Uint8List(Attachment.maxBytes),
    );
    expect(attachment.bytes.length, Attachment.maxBytes);
  });
  test('oversized attachment is rejected before encryption', () {
    expect(
      () =>
          Attachment(name: 'large', bytes: Uint8List(Attachment.maxBytes + 1)),
      throwsArgumentError,
    );
  });
  test('filename cannot contain a path', () {
    expect(
      () => Attachment(name: '../secret', bytes: Uint8List(1)),
      throwsArgumentError,
    );
  });
  test('corrupted metadata is rejected on decode', () {
    expect(() => Attachment.decode('not json'), throwsFormatException);
    expect(
      () => Attachment.decode('{"name":"x.bin"}'),
      throwsA(isA<TypeError>()),
    );
    expect(
      () => Attachment.decode('{"name":"x.bin","data":"not-base64!!"}'),
      throwsFormatException,
    );
  });

  group('caption', () {
    test('survives encoding and is trimmed', () {
      final restored = Attachment.decode(
        Attachment(
          name: 'IMG_1.jpg',
          bytes: Uint8List.fromList([1, 2]),
          caption: '  Pohled z okna \u{1F305}\n2. radek  ',
        ).encode(),
      );
      expect(restored.caption, 'Pohled z okna \u{1F305}\n2. radek');
      expect(restored.bytes, [1, 2]);
    });

    test('an empty caption is left out of the wire body', () {
      for (final caption in [null, '', '   ']) {
        final body = Attachment(
          name: 'a.jpg',
          bytes: Uint8List(1),
          caption: caption,
        ).encode();
        expect(jsonDecode(body), isNot(contains('caption')));
        expect(Attachment.decode(body).caption, isNull);
      }
    });

    test('an old body without a caption still decodes', () {
      final old = jsonEncode({
        'name': 'old.png',
        'data': base64Encode([7]),
      });
      final restored = Attachment.decode(old);
      expect(restored.name, 'old.png');
      expect(restored.bytes, [7]);
      expect(restored.caption, isNull);
    });

    test('old readers see only name and data', () {
      final body = Attachment(
        name: 'a.jpg',
        bytes: Uint8List(1),
        caption: 'hi',
      ).encode();
      final map = jsonDecode(body) as Map<String, dynamic>;
      expect(map.keys.toSet(), {'name', 'data', 'caption'});
      // What a pre-caption client did with the body:
      expect(map['name'], 'a.jpg');
      expect(base64Decode(map['data'] as String), [0]);
    });

    test('a too long caption is cut, a non-string one ignored', () {
      final long = Attachment(
        name: 'a.jpg',
        bytes: Uint8List(1),
        caption: 'x' * (Attachment.maxCaptionLength + 50),
      );
      expect(long.caption!.length, Attachment.maxCaptionLength);
      final odd = jsonEncode({
        'name': 'a.jpg',
        'data': base64Encode([1]),
        'caption': 42,
      });
      expect(Attachment.decode(odd).caption, isNull);
    });

    test('a full-size photo with a long caption fits the decode limit', () {
      final body = Attachment(
        name: 'a.jpg',
        bytes: Uint8List(Attachment.maxBytes),
        caption: '\u{1F468}\u200D\u{1F469}' * Attachment.maxCaptionLength,
      ).encode();
      expect(Attachment.decode(body).bytes.length, Attachment.maxBytes);
    });
  });
}
