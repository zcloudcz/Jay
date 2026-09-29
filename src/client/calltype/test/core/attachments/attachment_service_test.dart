import 'dart:typed_data';

import 'package:calltype/core/attachments/attachment_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const service = UnavailableAttachmentService();
  final isUnavailable = throwsA(
    isA<AttachmentException>().having(
      (e) => e.code,
      'code',
      AttachmentErrorCode.unavailable,
    ),
  );

  test('the X0 stub fails every call with unavailable, never silently', () {
    expect(
      service.upload(
        AttachmentSource.memory(Uint8List(3)),
        const MediaMetadata(kind: MediaKind.image, mime: 'image/jpeg'),
      ),
      isUnavailable,
    );
    expect(service.deleteRemote('b'), isUnavailable);
    expect(service.deleteLocal('b'), isUnavailable);
    expect(service.cacheSizeBytes(), isUnavailable);
    expect(service.watch('t').first, isUnavailable);
  });

  test('TransferProgress.fraction treats an empty transfer as done', () {
    expect(const TransferProgress('t', 0, 0, TransferState.done).fraction, 1);
    expect(
      const TransferProgress('t', 25, 100, TransferState.running).fraction,
      0.25,
    );
  });
}
