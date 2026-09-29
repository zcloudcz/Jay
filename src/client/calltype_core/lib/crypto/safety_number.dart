import 'dart:typed_data';

/// X0 STUB — frozen signatures of stream S (S5, contracts K9) so stream G
/// can build the verification UI against them. Stream S replaces every
/// `UnimplementedError` with the real algorithm (iterated SHA-512 ×5200,
/// domain separator `CallType-SafetyNumber-v1`, QR `jaysn:1:`) and adds the
/// test vectors from the S plan. Do not change the signatures without
/// updating `2026-09-29-gap-contracts.md`.

/// One side of a safety-number comparison. Keys are base64, 32 bytes each.
class PartyIdentity {
  const PartyIdentity({
    required this.deviceId,
    required this.identityKey,
    required this.signingKey,
  });

  final String deviceId;
  final String identityKey;
  final String signingKey;
}

/// Result of scanning the OTHER device's safety-number QR code.
enum SafetyNumberScanResult { match, mismatch, unsupportedVersion, malformed }

/// Safety number between this device ([compute]'s `local`) and a peer.
class SafetyNumber {
  // ignore: unused_element — the constructor S5's compute() will call.
  SafetyNumber._(this.digits, this.qrPayload);

  static const version = 1;
  static const iterations = 5200;

  /// Synchronous on purpose (package:crypto SHA-512): G may run it in
  /// `compute()` on the web if it turns out slow there.
  factory SafetyNumber.compute({
    required PartyIdentity local,
    required PartyIdentity remote,
  }) {
    throw UnimplementedError('SafetyNumber.compute is implemented by S5');
  }

  /// 32-byte per-party fingerprint; also the invite QR `fp` parameter.
  static Uint8List fingerprint(PartyIdentity party) {
    throw UnimplementedError('SafetyNumber.fingerprint is implemented by S5');
  }

  /// base64url without padding of [fingerprint] (43 characters).
  static String fingerprintBase64Url(PartyIdentity party) {
    throw UnimplementedError(
      'SafetyNumber.fingerprintBase64Url is implemented by S5',
    );
  }

  /// 60 digits, identical on both devices.
  final String digits;

  /// 12 groups of 5 digits, for display.
  List<String> get groups => [
    for (var i = 0; i < digits.length; i += 5) digits.substring(i, i + 5),
  ];

  /// Payload of the QR code shown by the LOCAL device.
  final String qrPayload;

  /// Checks a payload shown by the OTHER device.
  SafetyNumberScanResult verifyScanned(String payload) {
    throw UnimplementedError('SafetyNumber.verifyScanned is implemented by S5');
  }
}
