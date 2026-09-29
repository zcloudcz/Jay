import 'package:calltype_core/messaging/control_messages.dart';
import 'package:test/test.dart';

void main() {
  test('known control types are control with or without ctl', () {
    for (final type in knownControlTypes) {
      expect(isControlPayload({'type': type}), isTrue, reason: type);
      expect(isControlPayload({'type': type, 'ctl': true}), isTrue);
    }
  });

  test('an unknown type is control only when it declares ctl: true', () {
    expect(isControlPayload({'type': 'future-thing', 'ctl': true}), isTrue);
    expect(isControlPayload({'type': 'future-thing'}), isFalse);
    // Only the JSON literal true counts — not "true" or 1.
    expect(isControlPayload({'type': 'future-thing', 'ctl': 'true'}), isFalse);
    expect(isControlPayload({'type': 'future-thing', 'ctl': 1}), isFalse);
  });

  test('content types are not control', () {
    for (final type in [
      MessageTypes.text,
      MessageTypes.file,
      MessageTypes.callEvent,
      MessageTypes.media,
    ]) {
      expect(isControlPayload({'type': type}), isFalse, reason: type);
    }
  });

  test('payloadType defaults to text and rejects a malformed type', () {
    expect(payloadType({}), 'text');
    expect(payloadType({'type': 'media'}), 'media');
    expect(() => payloadType({'type': 3}), throwsFormatException);
    expect(() => payloadType({'type': ''}), throwsFormatException);
  });
}
