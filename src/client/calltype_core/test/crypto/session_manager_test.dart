import 'dart:convert';

import 'package:test/test.dart';

import '../helpers/test_device.dart';

/// End-to-end tests of the X3DH + Double Ratchet implementation.
///
/// Two complete "devices" (Alice and Bob) are simulated, each with its own
/// in-memory database and in-memory secure storage. The server is simulated
/// by handing Alice a key bundle built from Bob's public keys — exactly the
/// JSON shape `GET /devices/{id}/key-bundle` returns. Messages travel as
/// the JSON envelopes [SessionManager.encryptMessage] produces, so these
/// tests cover the real wire format end to end.
void main() {
  late TestDevice alice;
  late TestDevice bob;

  setUp(() async {
    alice = await TestDevice.create('alice');
    bob = await TestDevice.create('bob');
  });

  tearDown(() async {
    await alice.close();
    await bob.close();
  });

  /// Simulates `GET /devices/{bob}/key-bundle`: Bob's public keys plus one
  /// consumed one-time pre-key, in the server's response shape.
  Future<Map<String, dynamic>> bobKeyBundle({bool includeOneTime = true}) =>
      bob.keyBundle(includeOneTime: includeOneTime);

  group('Session establishment (X3DH)', () {
    test('first message decrypts on responder without prior contact',
        () async {
      await alice.sessions.initiateSession(bob.id, await bobKeyBundle());

      final envelope = await alice.sessions.encryptMessage(bob.id, 'hello bob');
      final decrypted = await bob.sessions.decryptMessage(alice.id, envelope);

      expect(decrypted, equals('hello bob'));
    });

    test('first message is a pre-key message with the X3DH prologue',
        () async {
      await alice.sessions.initiateSession(bob.id, await bobKeyBundle());

      final envelope = jsonDecode(
        await alice.sessions.encryptMessage(bob.id, 'hi'),
      ) as Map<String, dynamic>;

      expect(envelope['t'], equals('pk'));
      expect(envelope['ik'], isNotNull);
      expect(envelope['ek'], isNotNull);
      expect(envelope['pkid'], isNotNull);
    });

    test('session works without a one-time pre-key (depleted server stock)',
        () async {
      await alice.sessions
          .initiateSession(bob.id, await bobKeyBundle(includeOneTime: false));

      final envelope = await alice.sessions.encryptMessage(bob.id, 'no otk');

      expect(await bob.sessions.decryptMessage(alice.id, envelope),
          equals('no otk'));
    });

    test('replayed pre-key message cannot re-establish a session', () async {
      await alice.sessions.initiateSession(bob.id, await bobKeyBundle());
      final envelope = await alice.sessions.encryptMessage(bob.id, 'first');
      await bob.sessions.decryptMessage(alice.id, envelope);

      // Simulate an attacker replaying the captured initial message to a
      // Bob that lost his session (fresh DB) — the one-time pre-key was
      // already consumed, so establishment must fail.
      final bobReinstalled = await TestDevice.createWithSecureStorage(
        'bob',
        bob.secureStorage,
      );

      await expectLater(
        bobReinstalled.sessions.decryptMessage(alice.id, envelope),
        throwsStateError,
      );

      await bobReinstalled.close();
    });

    test('normal message without an existing session is rejected', () async {
      await alice.sessions.initiateSession(bob.id, await bobKeyBundle());
      // Receive one message so Bob's session exists and Alice's pending
      // X3DH prologue clears...
      final first = await alice.sessions.encryptMessage(bob.id, 'one');
      await bob.sessions.decryptMessage(alice.id, first);
      final reply = await bob.sessions.encryptMessage(alice.id, 'two');
      await alice.sessions.decryptMessage(bob.id, reply);

      // ...then a normal (non-pre-key) message hits a device with no session.
      final normal = await alice.sessions.encryptMessage(bob.id, 'three');
      final stranger = await TestDevice.create('stranger');

      await expectLater(
        stranger.sessions.decryptMessage(alice.id, normal),
        throwsStateError,
      );

      await stranger.close();
    });
  });

  group('Double Ratchet', () {
    test('full conversation round-trips in both directions', () async {
      await alice.sessions.initiateSession(bob.id, await bobKeyBundle());

      final transcript = [
        (alice, bob, 'hey'),
        (alice, bob, 'you there?'),
        (bob, alice, 'yes!'),
        (alice, bob, 'great'),
        (bob, alice, 'how are you'),
        (bob, alice, 'still there?'),
        (alice, bob, 'yep'),
      ];

      for (final (sender, receiver, text) in transcript) {
        final envelope =
            await sender.sessions.encryptMessage(receiver.id, text);
        final decrypted =
            await receiver.sessions.decryptMessage(sender.id, envelope);
        expect(decrypted, equals(text), reason: 'message "$text" corrupted');
      }
    });

    test('ratchet key rotates on every direction change (DH ratchet)',
        () async {
      await alice.sessions.initiateSession(bob.id, await bobKeyBundle());

      String ratchetKeyOf(String envelope) =>
          (jsonDecode(envelope) as Map<String, dynamic>)['rk'] as String;

      final a1 = await alice.sessions.encryptMessage(bob.id, 'a1');
      final a2 = await alice.sessions.encryptMessage(bob.id, 'a2');
      await bob.sessions.decryptMessage(alice.id, a1);
      await bob.sessions.decryptMessage(alice.id, a2);

      final b1 = await bob.sessions.encryptMessage(alice.id, 'b1');
      await alice.sessions.decryptMessage(bob.id, b1);

      final a3 = await alice.sessions.encryptMessage(bob.id, 'a3');

      // Same chain → same ratchet key; after receiving Bob's reply Alice
      // must have rotated to a fresh ratchet pair (this rotation is the
      // self-healing property of the Double Ratchet).
      expect(ratchetKeyOf(a1), equals(ratchetKeyOf(a2)));
      expect(ratchetKeyOf(b1), isNot(equals(ratchetKeyOf(a1))));
      expect(ratchetKeyOf(a3), isNot(equals(ratchetKeyOf(a1))));
    });

    test('out-of-order delivery within one chain (skipped message keys)',
        () async {
      await alice.sessions.initiateSession(bob.id, await bobKeyBundle());

      final e1 = await alice.sessions.encryptMessage(bob.id, 'first');
      final e2 = await alice.sessions.encryptMessage(bob.id, 'second');
      final e3 = await alice.sessions.encryptMessage(bob.id, 'third');

      // Deliver 3, then 1, then 2 — all must decrypt correctly.
      expect(await bob.sessions.decryptMessage(alice.id, e3), 'third');
      expect(await bob.sessions.decryptMessage(alice.id, e1), 'first');
      expect(await bob.sessions.decryptMessage(alice.id, e2), 'second');
    });

    test('message delayed across a DH ratchet step still decrypts', () async {
      await alice.sessions.initiateSession(bob.id, await bobKeyBundle());

      // Alice sends two; the second is delayed in transit.
      final a1 = await alice.sessions.encryptMessage(bob.id, 'a1');
      final delayed = await alice.sessions.encryptMessage(bob.id, 'delayed');
      await bob.sessions.decryptMessage(alice.id, a1);

      // A full round-trip happens, advancing the DH ratchet on both sides.
      final b1 = await bob.sessions.encryptMessage(alice.id, 'b1');
      await alice.sessions.decryptMessage(bob.id, b1);
      final a2 = await alice.sessions.encryptMessage(bob.id, 'a2');
      await bob.sessions.decryptMessage(alice.id, a2);

      // The delayed message from the OLD chain finally arrives.
      expect(await bob.sessions.decryptMessage(alice.id, delayed), 'delayed');
    });

    test('tampered ciphertext fails authentication', () async {
      await alice.sessions.initiateSession(bob.id, await bobKeyBundle());

      final envelope = jsonDecode(
        await alice.sessions.encryptMessage(bob.id, 'secret'),
      ) as Map<String, dynamic>;

      // Flip one byte in the ciphertext.
      final bytes = base64Decode(envelope['c'] as String);
      bytes[bytes.length ~/ 2] ^= 0xFF;
      envelope['c'] = base64Encode(bytes);

      await expectLater(
        bob.sessions.decryptMessage(alice.id, jsonEncode(envelope)),
        throwsA(anything),
      );
    });

    test('tampered header (message number) fails authentication', () async {
      await alice.sessions.initiateSession(bob.id, await bobKeyBundle());
      // Establish both directions so header tampering hits a live chain.
      final first = await alice.sessions.encryptMessage(bob.id, 'one');
      await bob.sessions.decryptMessage(alice.id, first);

      final envelope = jsonDecode(
        await alice.sessions.encryptMessage(bob.id, 'two'),
      ) as Map<String, dynamic>;

      // The header is plaintext but bound to the ciphertext as AES-GCM AAD —
      // bumping the message number must break authentication, not silently
      // decrypt with a skipped key.
      envelope['n'] = (envelope['n'] as int) + 1;

      await expectLater(
        bob.sessions.decryptMessage(alice.id, jsonEncode(envelope)),
        throwsA(anything),
      );
    });

    test('replayed message is rejected', () async {
      await alice.sessions.initiateSession(bob.id, await bobKeyBundle());

      final envelope = await alice.sessions.encryptMessage(bob.id, 'once');
      await bob.sessions.decryptMessage(alice.id, envelope);

      // Second delivery of the same envelope: its message key was already
      // consumed and the chain has advanced past it.
      await expectLater(
        bob.sessions.decryptMessage(alice.id, envelope),
        throwsA(anything),
      );
    });

    test('two messages never share a ciphertext or message key', () async {
      await alice.sessions.initiateSession(bob.id, await bobKeyBundle());

      final e1 = jsonDecode(await alice.sessions.encryptMessage(bob.id, 'same'))
          as Map<String, dynamic>;
      final e2 = jsonDecode(await alice.sessions.encryptMessage(bob.id, 'same'))
          as Map<String, dynamic>;

      // Identical plaintext must produce different ciphertexts (fresh
      // message key + fresh nonce every time).
      expect(e1['c'], isNot(equals(e2['c'])));
      expect(e1['n'], isNot(equals(e2['n'])));
    });

    test('absurd message number jump is refused (DoS guard)', () async {
      await alice.sessions.initiateSession(bob.id, await bobKeyBundle());
      final first = await alice.sessions.encryptMessage(bob.id, 'one');
      await bob.sessions.decryptMessage(alice.id, first);

      final envelope = jsonDecode(
        await alice.sessions.encryptMessage(bob.id, 'two'),
      ) as Map<String, dynamic>;
      // Pretend thousands of messages were skipped — must be refused
      // before any expensive key derivation happens.
      envelope['n'] = 100000;

      await expectLater(
        bob.sessions.decryptMessage(alice.id, jsonEncode(envelope)),
        throwsStateError,
      );
    });
  });
}
