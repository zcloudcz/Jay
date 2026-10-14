import 'dart:convert';

import 'package:calltype_core/crypto/device_list.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

const primaryId = '11111111-1111-4111-8111-111111111111';
const companionId = '22222222-2222-4222-8222-222222222222';
const strangerId = '33333333-3333-4333-8333-333333333333';

Future<String> publicKeyOf(SimpleKeyPair pair) async =>
    base64Encode((await pair.extractPublicKey()).bytes);

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

  Future<SignedDeviceList> signed(List<DeviceListEntry> devices, {int version = 1}) =>
      signDeviceList(
        primarySigningKey: primary,
        list: DeviceList(primaryDeviceId: primaryId, version: version, devices: devices),
      );

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
      throwsA(isA<DeviceListException>()),
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
      throwsA(isA<DeviceListException>()),
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
      throwsA(isA<DeviceListException>()),
    );
  });

  test('a replayed lower version is rejected', () async {
    final old = await signed([await entry()], version: 2);
    expect(verify(old, minVersion: 3), throwsA(isA<DeviceListException>()));
  });

  test('a device that consented to a different primary is rejected', () async {
    // Without this check a user could list a stranger's device and the
    // stranger's messages would be shown to peers as the user's own.
    final list = await signed([await entry(consentFor: strangerId)]);
    expect(verify(list), throwsA(isA<DeviceListException>()));
  });

  test('more than five companions, duplicates and self-listing are rejected', () async {
    final six = [
      for (var i = 0; i < 6; i++)
        await entry(deviceId: '4444444$i-4444-4444-8444-444444444444'),
    ];
    expect(verify(await signed(six)), throwsA(isA<DeviceListException>()));
    final twice = [await entry(), await entry()];
    expect(verify(await signed(twice)), throwsA(isA<DeviceListException>()));
    final self = [await entry(deviceId: primaryId)];
    expect(verify(await signed(self)), throwsA(isA<DeviceListException>()));
  });

  test('a consent signature does not verify as a list signature', () async {
    // Domain separation: the two signatures must never be interchangeable.
    final consent = (await entry()).consentSig;
    final good = await signed([]);
    expect(
      verify(SignedDeviceList(good.payload, consent)),
      throwsA(isA<DeviceListException>()),
    );
  });
}
