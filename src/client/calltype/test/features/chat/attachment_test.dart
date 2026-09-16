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
}
