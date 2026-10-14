import 'dart:convert';

import 'package:crypto/crypto.dart';

/// What a new device shows as a QR code while it waits to be linked:
/// `jaylink://<deviceId>/<fingerprint>`.
///
/// WHY its own scheme: the contact scanner accepts `ct://` and `calltype://`.
/// A link code read as a contact invite would add the new device as a
/// contact, which marks it as somebody's identity and locks it out of
/// linking (DeviceDirectory refuses to attribute a device that is a contact).
class LinkCode {
  const LinkCode(this.deviceId, this.fingerprint);

  final String deviceId;
  final String fingerprint;

  static const scheme = 'jaylink';
  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );
  static final _sha256Hex = RegExp(r'^[0-9a-f]{64}$');

  @override
  String toString() => '$scheme://$deviceId/$fingerprint';

  static LinkCode? parse(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.scheme != scheme || uri.pathSegments.length != 1) {
      return null;
    }
    final deviceId = uri.host.toLowerCase();
    final fingerprint = uri.pathSegments.single.toLowerCase();
    if (!_uuid.hasMatch(deviceId) || !_sha256Hex.hasMatch(fingerprint)) {
      return null;
    }
    return LinkCode(deviceId, fingerprint);
  }
}

/// SHA-256 over `<identityKey>|<signingKey>` (base64, as the key bundle
/// serves them). The primary compares it with the bundle the SERVER returns
/// before anything is sent, so the server never chooses which keys get
/// linked (spec Part A, step 2).
String linkFingerprint(String identityKey, String signingKey) =>
    sha256.convert(utf8.encode('$identityKey|$signingKey')).toString();
