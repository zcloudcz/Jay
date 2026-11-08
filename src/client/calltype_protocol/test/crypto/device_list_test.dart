import 'dart:convert';

import 'package:calltype_protocol/crypto/device_list.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

const primaryId = '11111111-1111-4111-8111-111111111111';
const companionId = '22222222-2222-4222-8222-222222222222';
const strangerId = '33333333-3333-4333-8333-333333333333';

Future<String> publicKeyOf(SimpleKeyPair pair) async =>
    base64Encode((await pair.extractPublicKey()).bytes);

Matcher rejects(String reason) => throwsA(
  isA<DeviceListException>().having((e) => e.reason, 'reason', reason),
);

void main() {
  late SimpleKeyPair primary;
  late SimpleKeyPair companion;
  late String primaryKey;

  setUp(() async {
    primary = await Ed25519().newKeyPair();
    companion = await Ed25519().newKeyPair();
    primaryKey = await publicKeyOf(primary);
  });

  Future<DeviceListEntry> entry({
    String deviceId = companionId,
    String consentFor = primaryId,
  }) async => DeviceListEntry(
    deviceId: deviceId,
    identityKey: base64Encode(List.filled(32, 7)),
    signingKey: await publicKeyOf(companion),
    consentSig: await signDeviceLinkConsent(
      companionSigningKey: companion,
      primaryDeviceId: consentFor,
      companionDeviceId: deviceId,
    ),
  );

  // The signer refuses to build a consent for a bad id, so a hostile primary's
  // entry is assembled by hand with a placeholder consent.
  Future<DeviceListEntry> badIdEntry(String deviceId) async => DeviceListEntry(
    deviceId: deviceId,
    identityKey: base64Encode(List.filled(32, 7)),
    signingKey: await publicKeyOf(companion),
    consentSig: base64Encode(List.filled(64, 1)),
  );

  Future<SignedDeviceList> signed(List<DeviceListEntry> devices, {int version = 1}) =>
      signDeviceList(
        primarySigningKey: primary,
        list: DeviceList(primaryDeviceId: primaryId, version: version, devices: devices),
      );

  // Signs arbitrary payload bytes like a buggy or hostile primary would, so
  // the verifier is tested against validly signed but odd payloads.
  Future<SignedDeviceList> signRaw(List<int> payload) async {
    final sig = await Ed25519().sign([
      ...utf8.encode('CallType-DeviceList-v1\u0000'),
      ...payload,
    ], keyPair: primary);
    return SignedDeviceList(base64Encode(payload), base64Encode(sig.bytes));
  }

  Future<SignedDeviceList> signJson(Object json) =>
      signRaw(utf8.encode(jsonEncode(json)));

  Future<DeviceList> verify(SignedDeviceList list, {int minVersion = 1}) =>
      verifyDeviceList(
        signed: list,
        primarySigningKey: primaryKey,
        expectedPrimaryDeviceId: primaryId,
        minVersion: minVersion,
      );

  test('a signed list round-trips and exposes every device', () async {
    final list = await verify(await signed([await entry()]));
    expect(list.version, 1);
    expect(list.allDeviceIds, [primaryId, companionId]);
  });

  test('one flipped payload byte fails verification', () async {
    final good = await signed([await entry()]);
    final bytes = base64Decode(good.payload);
    bytes[bytes.length - 2] ^= 1;
    expect(
      verify(SignedDeviceList(base64Encode(bytes), good.signature)),
      rejects('bad_signature'),
    );
  });

  test('a list signed by another key is rejected', () async {
    final good = await signed([await entry()]);
    expect(
      verifyDeviceList(
        signed: good,
        primarySigningKey: await publicKeyOf(companion),
        expectedPrimaryDeviceId: primaryId,
      ),
      rejects('bad_signature'),
    );
  });

  test('a list for another primary is rejected', () async {
    final good = await signed([await entry()]);
    expect(
      verifyDeviceList(
        signed: good,
        primarySigningKey: primaryKey,
        expectedPrimaryDeviceId: strangerId,
      ),
      rejects('wrong_primary'),
    );
  });

  test('a replayed lower version is rejected', () async {
    final old = await signed([await entry()], version: 2);
    expect(verify(old, minVersion: 3), rejects('rollback'));
  });

  test('a device that consented to a different primary is rejected', () async {
    // Without this check a user could list a stranger's device and the
    // stranger's messages would be shown to peers as the user's own.
    final list = await signed([await entry(consentFor: strangerId)]);
    expect(verify(list), rejects('missing_consent'));
  });

  test('more than five companions are rejected', () async {
    final six = [
      for (var i = 0; i < 6; i++)
        await entry(deviceId: '4444444$i-4444-4444-8444-444444444444'),
    ];
    expect(verify(await signed(six)), rejects('too_many_devices'));
  });

  test('a duplicate companion is rejected', () async {
    final twice = [await entry(), await entry()];
    expect(verify(await signed(twice)), rejects('duplicate_device'));
  });

  test('the primary listed as its own companion is rejected', () async {
    final self = [await entry(deviceId: primaryId)];
    expect(verify(await signed(self)), rejects('duplicate_device'));
  });

  test('non-canonical spellings of a device id are rejected', () async {
    // The no-dash and "+" forms would parse to the same 16 bytes as the
    // canonical id and slip past the duplicate / self checks.
    for (final bad in [
      '22222222222242228222222222222222',
      '+2222222-2222-4222-8222-222222222222',
    ]) {
      expect(
        verify(await signed([await badIdEntry(bad)])),
        rejects('bad_device_id'),
      );
    }
  });

  test('a dash-less alias of the primary is rejected', () async {
    final alias = [await badIdEntry(primaryId.replaceAll('-', ''))];
    expect(verify(await signed(alias)), rejects('bad_device_id'));
  });

  test('a companion key swapped and re-signed by the primary is rejected', () async {
    // The primary can sign anything, but it cannot forge the companion's
    // consent for a key the companion never held.
    final good = await entry();
    final other = await Ed25519().newKeyPair();
    final swapped = DeviceListEntry(
      deviceId: good.deviceId,
      identityKey: good.identityKey,
      signingKey: await publicKeyOf(other),
      consentSig: good.consentSig,
    );
    expect(verify(await signed([swapped])), rejects('missing_consent'));
  });

  test('an empty consent signature is rejected', () async {
    final good = await entry();
    final empty = DeviceListEntry(
      deviceId: good.deviceId,
      identityKey: good.identityKey,
      signingKey: good.signingKey,
      consentSig: '',
    );
    expect(verify(await signed([empty])), rejects('missing_consent'));
  });

  test('a consent signature does not verify as a list signature', () async {
    // Domain separation: the two signatures must never be interchangeable.
    final consent = (await entry()).consentSig;
    final good = await signed([]);
    expect(
      verify(SignedDeviceList(good.payload, consent)),
      rejects('bad_signature'),
    );
  });

  test('validly signed but malformed payloads are rejected', () async {
    expect(verify(await signRaw(utf8.encode('not json'))), rejects('malformed'));
    expect(verify(await signJson([1, 2])), rejects('malformed'));
    expect(
      verify(
        await signJson({
          'primaryDeviceId': primaryId,
          'version': '1',
          'devices': [],
        }),
      ),
      rejects('malformed'),
    );
  });

  test('a signed payload with an extra field is rejected', () async {
    // Server and client parsers must see the same device set, so only the
    // exact canonical encoding is accepted.
    final extra = await signJson({
      'primaryDeviceId': primaryId,
      'version': 1,
      'devices': [],
      'note': 'x',
    });
    expect(verify(extra), rejects('malformed'));
  });

  test('a signed payload with extra whitespace is rejected', () async {
    final spaced = await signRaw(
      utf8.encode('{"primaryDeviceId": "$primaryId","version":1,"devices":[]}'),
    );
    expect(verify(spaced), rejects('malformed'));
  });

  test('an oversized payload is rejected before any decoding', () async {
    final big = SignedDeviceList(base64Encode(List.filled(20000, 65)), 'AA==');
    expect(verify(big), rejects('malformed'));
  });

  test('a consent for a malformed device id verifies as false', () async {
    expect(
      await verifyDeviceLinkConsent(
        consentSig: (await entry()).consentSig,
        companionSigningKey: await publicKeyOf(companion),
        primaryDeviceId: primaryId,
        companionDeviceId: 'not-a-uuid',
      ),
      isFalse,
    );
  });
}
