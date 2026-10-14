import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Multi-device trust: the list of companion devices an identity vouches for.
///
/// WHY it exists: fan-out to several devices needs somebody to say "this is
/// also my device". If the server said it, the server could add a reader.
/// So the PRIMARY device signs the list with its Ed25519 signing key, which
/// peers already pin (`peer_identity:<deviceId>`), and every client verifies
/// before encrypting for any listed device.
///
/// WHY the signature covers the exact stored bytes: there is then no JSON
/// canonicalization to get wrong. Verify first, parse second.

/// Protocol domain separators. Like the other `CallType-*` strings in this
/// folder they must never be renamed: every existing list would stop verifying.
const _listDomain = 'CallType-DeviceList-v1\u0000';
const _consentDomain = 'CallType-DeviceLink-v1\u0000';

const maxCompanionDevices = 5;

class DeviceListException implements Exception {
  const DeviceListException(this.reason);
  final String reason;
  @override
  String toString() => 'DeviceListException: $reason';
}

class DeviceListEntry {
  const DeviceListEntry({
    required this.deviceId,
    required this.identityKey,
    required this.signingKey,
    required this.consentSig,
  });

  final String deviceId;

  /// X25519 identity key and Ed25519 signing key of the companion (base64).
  /// Listing them stops the server from swapping the companion's key bundle.
  final String identityKey;
  final String signingKey;

  /// The companion's own signature over (primary, companion): proof it agreed.
  final String consentSig;

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'identityKey': identityKey,
    'signingKey': signingKey,
    'consentSig': consentSig,
  };
}

class DeviceList {
  const DeviceList({
    required this.primaryDeviceId,
    required this.version,
    required this.devices,
  });

  final String primaryDeviceId;
  final int version;

  /// Companions only. The primary is implicit.
  final List<DeviceListEntry> devices;

  List<String> get allDeviceIds => [
    primaryDeviceId,
    ...devices.map((d) => d.deviceId),
  ];
}

/// The list as it travels and is stored: base64 payload + base64 signature.
class SignedDeviceList {
  const SignedDeviceList(this.payload, this.signature);
  final String payload;
  final String signature;
}

/// One device must have exactly one spelling. Without this, "+1.." or a
/// dash-less form would map to the same 16 bytes as the canonical id and
/// defeat the duplicate / self-listing checks, and string-keyed lookups
/// downstream would disagree with the byte-level consent message.
final _canonicalUuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

Uint8List _uuidBytes(String uuid) {
  if (!_canonicalUuid.hasMatch(uuid)) {
    throw const DeviceListException('bad_device_id');
  }
  final hex = uuid.replaceAll('-', '');
  try {
    return Uint8List.fromList([
      for (var i = 0; i < 32; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);
  } on FormatException {
    throw const DeviceListException('bad_device_id');
  }
}

List<int> _consentMessage(String primaryDeviceId, String companionDeviceId) => [
  ...utf8.encode(_consentDomain),
  ..._uuidBytes(primaryDeviceId),
  ..._uuidBytes(companionDeviceId),
];

/// Called on the COMPANION: "I agree to be a device of [primaryDeviceId]".
Future<String> signDeviceLinkConsent({
  required SimpleKeyPair companionSigningKey,
  required String primaryDeviceId,
  required String companionDeviceId,
}) async => base64Encode(
  (await Ed25519().sign(
    _consentMessage(primaryDeviceId, companionDeviceId),
    keyPair: companionSigningKey,
  )).bytes,
);

Future<bool> verifyDeviceLinkConsent({
  required String consentSig,
  required String companionSigningKey,
  required String primaryDeviceId,
  required String companionDeviceId,
}) async {
  try {
    final key = base64Decode(companionSigningKey);
    final signature = base64Decode(consentSig);
    if (key.length != 32 || signature.length != 64) return false;
    return Ed25519().verify(
      _consentMessage(primaryDeviceId, companionDeviceId),
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(key, type: KeyPairType.ed25519),
      ),
    );
  } on FormatException {
    return false;
  } on DeviceListException {
    // A malformed id is "no valid consent", not a crash for the caller.
    return false;
  }
}

/// The one place that defines the signed payload shape. Signing and the
/// canonical-form check in [verifyDeviceList] both use it so they cannot drift.
String _encodeList(DeviceList list) => jsonEncode({
  'primaryDeviceId': list.primaryDeviceId,
  'version': list.version,
  'devices': [for (final d in list.devices) d.toJson()],
});

/// Called on the PRIMARY.
Future<SignedDeviceList> signDeviceList({
  required SimpleKeyPair primarySigningKey,
  required DeviceList list,
}) async {
  final payload = utf8.encode(_encodeList(list));
  final signature = await Ed25519().sign([
    ...utf8.encode(_listDomain),
    ...payload,
  ], keyPair: primarySigningKey);
  return SignedDeviceList(base64Encode(payload), base64Encode(signature.bytes));
}

/// Parses a payload WITHOUT verifying it. Only for bytes that were verified
/// before they were stored (see DeviceDirectory).
DeviceList parseDeviceListPayload(String payload) {
  try {
    final json = jsonDecode(utf8.decode(base64Decode(payload)));
    if (json is! Map<String, dynamic>) {
      throw const DeviceListException('malformed');
    }
    final list = DeviceList(
      primaryDeviceId: (json['primaryDeviceId'] as String).toLowerCase(),
      version: json['version'] as int,
      devices: [
        for (final d in json['devices'] as List)
          DeviceListEntry(
            deviceId: ((d as Map)['deviceId'] as String).toLowerCase(),
            identityKey: d['identityKey'] as String,
            signingKey: d['signingKey'] as String,
            consentSig: d['consentSig'] as String,
          ),
      ],
    );
    // Reject every non-canonical spelling of an id (see _canonicalUuid).
    for (final id in list.allDeviceIds) {
      if (!_canonicalUuid.hasMatch(id)) {
        throw const DeviceListException('bad_device_id');
      }
    }
    return list;
  } on DeviceListException {
    rethrow;
  } catch (_) {
    // FormatException, TypeError on a wrong shape: all the same to a caller.
    throw const DeviceListException('malformed');
  }
}

/// Verifies signature, owner, version floor, size and every consent.
/// [minVersion] is "highest version already accepted + 1" (1 for a first
/// list): a lower one is a replay of a list with a removed device.
///
/// CALLER CONTRACT: a valid consent only proves that the key listed in the
/// entry (`signingKey`) agreed. Before attributing a device to the identity,
/// callers MUST confirm that the listed `identityKey|signingKey` equal the
/// device's own authenticated keys (pinned `peer_identity:<deviceId>`), see
/// `DeviceDirectory.assertListedKeys`. Otherwise a signer could list a
/// stranger's device id together with a key pair of her own.
Future<DeviceList> verifyDeviceList({
  required SignedDeviceList signed,
  required String primarySigningKey,
  required String expectedPrimaryDeviceId,
  int minVersion = 1,
}) async {
  // A valid list (5 entries) is ~4 KB. A malicious server must not make us
  // copy megabytes before the signature check fails.
  if (signed.payload.length > 16 * 1024) {
    throw const DeviceListException('malformed');
  }
  late final List<int> payload;
  late final List<int> signature;
  late final List<int> key;
  try {
    payload = base64Decode(signed.payload);
    signature = base64Decode(signed.signature);
    key = base64Decode(primarySigningKey);
  } on FormatException {
    throw const DeviceListException('malformed');
  }
  if (signature.length != 64 || key.length != 32) {
    throw const DeviceListException('malformed');
  }
  final valid = await Ed25519().verify(
    [...utf8.encode(_listDomain), ...payload],
    signature: Signature(
      signature,
      publicKey: SimplePublicKey(key, type: KeyPairType.ed25519),
    ),
  );
  if (!valid) throw const DeviceListException('bad_signature');

  final list = parseDeviceListPayload(signed.payload);
  if (list.primaryDeviceId != expectedPrimaryDeviceId.toLowerCase()) {
    throw const DeviceListException('wrong_primary');
  }
  // The server derives routing from the same bytes with a different JSON
  // parser. Duplicate keys, extra fields or whitespace could make server and
  // clients see different device sets, so only the exact canonical encoding
  // is accepted.
  if (_encodeList(list) != utf8.decode(payload)) {
    throw const DeviceListException('malformed');
  }
  if (list.version < minVersion) throw const DeviceListException('rollback');
  if (list.devices.length > maxCompanionDevices) {
    throw const DeviceListException('too_many_devices');
  }
  final ids = list.devices.map((d) => d.deviceId).toSet();
  if (ids.length != list.devices.length ||
      ids.contains(list.primaryDeviceId)) {
    throw const DeviceListException('duplicate_device');
  }
  for (final device in list.devices) {
    final consented = await verifyDeviceLinkConsent(
      consentSig: device.consentSig,
      companionSigningKey: device.signingKey,
      primaryDeviceId: list.primaryDeviceId,
      companionDeviceId: device.deviceId,
    );
    if (!consented) throw const DeviceListException('missing_consent');
  }
  return list;
}
