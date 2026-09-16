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
}
