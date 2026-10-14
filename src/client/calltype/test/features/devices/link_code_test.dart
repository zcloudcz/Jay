import 'package:calltype/features/devices/link_code.dart';
import 'package:flutter_test/flutter_test.dart';

const id = 'a0000000-0000-4000-8000-000000000002';

void main() {
  final fingerprint = linkFingerprint('aWs=', 'c2s=');

  test('a code survives the QR round trip', () {
    final parsed = LinkCode.parse(LinkCode(id, fingerprint).toString())!;
    expect(parsed.deviceId, id);
    expect(parsed.fingerprint, fingerprint);
  });

  test('contact invites and malformed codes are not link codes', () {
    expect(LinkCode.parse('ct://$id/CT-AAAA-BBBB'), isNull);
    expect(LinkCode.parse('calltype://contact/CT-AAAA-BBBB'), isNull);
    expect(LinkCode.parse('jaylink://not-a-device/$fingerprint'), isNull);
    expect(LinkCode.parse('jaylink://$id/abc'), isNull);
    expect(LinkCode.parse('jaylink://$id/$fingerprint/extra'), isNull);
  });

  test('the fingerprint covers both keys', () {
    expect(fingerprint, hasLength(64));
    expect(linkFingerprint('aWs=', 'c2s='), fingerprint);
    expect(linkFingerprint('aWs=', 'b3RoZXI='), isNot(fingerprint));
    expect(linkFingerprint('b3RoZXI=', 'c2s='), isNot(fingerprint));
  });
}
