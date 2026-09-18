// Unit test (no server, no docker) for the Dart TOTP mirror of the server's
// TotpService.cs. Verified against RFC 6238 Appendix B SHA-1 test vectors
// (8-digit codes) before trusting it inside the live E2E flow.
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'totp.dart';

void main() {
  // RFC 6238 Appendix B, SHA-1 seed: 20 ASCII '1'..'2'..'0' bytes repeated
  // to 20 bytes ("12345678901234567890").
  final secret = Uint8List.fromList(utf8.encode('12345678901234567890'));

  test('RFC 6238 Appendix B SHA-1 vectors (8 digits)', () {
    // (unixTime, expected code) — time-step = unixTime / 30.
    const vectors = [
      (59, '94287082'),
      (1111111109, '07081804'),
      (1111111111, '14050471'),
      (1234567890, '89005924'),
      (2000000000, '69279037'),
    ];
    for (final (unixTime, expected) in vectors) {
      final step = unixTime ~/ 30;
      expect(computeTotp(secret, step, digits: 8), expected);
    }
  });

  test('base32Decode is the inverse of the server-side encode', () {
    // "12345678901234567890" base32-encoded (RFC 4648, no padding) by the
    // server's Base32.cs — cross-checked against the reference encoder.
    final decoded = base32Decode('GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ');
    expect(utf8.decode(decoded), '12345678901234567890');
  });

  test('currentTotpStep matches unixTime / 30', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1234567890 * 1000, isUtc: true);
    expect(currentTotpStep(now: now), 1234567890 ~/ 30);
  });
}
