// Hand-rolled RFC 6238 TOTP (HMAC-SHA1) — the Dart mirror of the server's
// TotpService.cs, so the live E2E tests can pass MFA without a real
// authenticator app. Kept minimal: only what enrollAndVerifyMfa needs.
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

const _period = 30;
const _digits = 6;

/// RFC 4648 base32 decode (no padding) — inverse of the server's Base32.cs,
/// needed to turn `secretBase32` from enroll/start back into raw key bytes.
Uint8List base32Decode(String input) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  final bytes = <int>[];
  var buffer = 0, bitsInBuffer = 0;
  for (final ch in input.trimRight().replaceAll('=', '').split('')) {
    final value = alphabet.indexOf(ch.toUpperCase());
    if (value < 0) continue;
    buffer = (buffer << 5) | value;
    bitsInBuffer += 5;
    if (bitsInBuffer >= 8) {
      bitsInBuffer -= 8;
      bytes.add((buffer >> bitsInBuffer) & 0xFF);
    }
  }
  return Uint8List.fromList(bytes);
}

/// The current RFC 6238 time-step (30s), matching TotpService.CurrentStep.
int currentTotpStep({DateTime? now}) =>
    (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch ~/ 1000 ~/ _period;

/// RFC 4226 HOTP + RFC 6238 counter=step, same truncation as
/// TotpService.ComputeCode. [digits] is parameterized (default 6) so RFC
/// 6238 Appendix B's 8-digit SHA-1 test vectors can reuse this function.
String computeTotp(Uint8List secret, int step, {int digits = _digits}) {
  final counter = ByteData(8)..setInt64(0, step, Endian.big);
  final hash = Hmac(sha1, secret).convert(counter.buffer.asUint8List()).bytes;

  final offset = hash[hash.length - 1] & 0x0f;
  final binary =
      ((hash[offset] & 0x7f) << 24) |
      ((hash[offset + 1] & 0xff) << 16) |
      ((hash[offset + 2] & 0xff) << 8) |
      (hash[offset + 3] & 0xff);

  final modulus = _pow10(digits);
  return (binary % modulus).toString().padLeft(digits, '0');
}

int _pow10(int n) {
  var result = 1;
  for (var i = 0; i < n; i++) {
    result *= 10;
  }
  return result;
}
