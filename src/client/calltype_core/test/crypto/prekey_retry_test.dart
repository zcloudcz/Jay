import 'dart:convert';
import 'package:test/test.dart';
import '../helpers/test_device.dart';

void main() {
  test(
    'tampered initial message does not burn the recipient one-time key',
    () async {
      final alice = await TestDevice.create('alice');
      final bob = await TestDevice.create('bob');
      addTearDown(alice.close);
      addTearDown(bob.close);
      await alice.sessions.initiateSession('bob', await bob.keyBundle());
      final envelope = await alice.sessions.encryptMessage('bob', 'hello');
      final forged = jsonDecode(envelope) as Map<String, dynamic>;
      final bytes = base64Decode(forged['c'] as String)..[15] ^= 1;
      forged['c'] = base64Encode(bytes);
      await expectLater(
        bob.sessions.decryptMessage('alice', jsonEncode(forged)),
        throwsA(anything),
      );
      expect(await bob.sessions.decryptMessage('alice', envelope), 'hello');
    },
  );
}
