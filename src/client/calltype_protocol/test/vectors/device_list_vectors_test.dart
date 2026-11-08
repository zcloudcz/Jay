import 'dart:convert';

import 'package:calltype_protocol/crypto/device_list.dart';
import 'package:calltype_protocol/testing/device_list_vector_scenario.dart';
import 'package:calltype_protocol/testing/session_vector_scenario.dart'
    show encodeVectors;
import 'package:test/test.dart';

void main() {
  test('regenerating from the code gives the committed file exactly', () async {
    expect(
      encodeVectors(await buildDeviceListVectors()),
      encodeVectors(loadDeviceListVectors()),
    );
  });

  test('the committed list verifies; payload is the canonical JSON', () async {
    final v = loadDeviceListVectors();
    final signed = SignedDeviceList(
      v['signed']['payload'] as String,
      v['signed']['signature'] as String,
    );
    expect(utf8.decode(base64Decode(signed.payload)), v['payloadText']);
    final list = await verifyDeviceList(
      signed: signed,
      primarySigningKey: v['primary']['signingKey'] as String,
      expectedPrimaryDeviceId: v['primary']['deviceId'] as String,
    );
    expect(list.version, v['listVersion']);
    expect(list.devices.map((d) => d.toJson()).toList(), [
      for (final c in v['companions'] as List) c['entry'],
    ]);
  });

  test('a flipped payload byte or a rollback is rejected', () async {
    final v = loadDeviceListVectors();
    final bytes = base64Decode(v['signed']['payload'] as String)..[10] ^= 1;
    await expectLater(
      verifyDeviceList(
        signed: SignedDeviceList(
          base64Encode(bytes),
          v['signed']['signature'] as String,
        ),
        primarySigningKey: v['primary']['signingKey'] as String,
        expectedPrimaryDeviceId: v['primary']['deviceId'] as String,
      ),
      throwsA(isA<DeviceListException>()),
    );
    await expectLater(
      verifyDeviceList(
        signed: SignedDeviceList(
          v['signed']['payload'] as String,
          v['signed']['signature'] as String,
        ),
        primarySigningKey: v['primary']['signingKey'] as String,
        expectedPrimaryDeviceId: v['primary']['deviceId'] as String,
        minVersion: 4,
      ),
      throwsA(isA<DeviceListException>()),
    );
  });
}
