import 'package:flutter_test/flutter_test.dart';
import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:calltype/core/crypto/key_manager.dart';
import 'package:calltype/core/storage/database.dart';
import '../../helpers/test_device.dart';

void main() {
  test(
    'first session fills the empty key of a manually added contact',
    () async {
      final alice = await TestDevice.create('alice');
      final bob = await TestDevice.create('bob');
      addTearDown(alice.close);
      addTearDown(bob.close);
      await alice.db
          .into(alice.db.contacts)
          .insert(
            ContactsCompanion.insert(
              deviceId: 'bob',
              userHandle: 'CT-BOB',
              identityKey: base64Decode(''),
              addedAt: DateTime.now(),
            ),
          );
      await alice.sessions.initiateSession('bob', await bob.keyBundle());
      expect(
        base64Encode(
          (await alice.db.select(alice.db.contacts).get()).single.identityKey,
        ),
        await bob.keys.getPublicIdentityKey(),
      );
    },
  );
  test(
    'relay cannot replace signed identity bundle and poison the first pin',
    () async {
      final alice = await TestDevice.create('alice');
      final bob = await TestDevice.create('bob');
      addTearDown(alice.close);
      addTearDown(bob.close);
      await alice.sessions.initiateSession('bob', await bob.keyBundle());
      final original = await alice.sessions.encryptMessage('bob', 'authentic');
      final forged = jsonDecode(original) as Map<String, dynamic>;
      final bundle = forged['identityBundle'] as Map<String, dynamic>;
      final attacker = await Ed25519().newKeyPair();
      final signature = await Ed25519().sign(
        KeyManager.signedIdentityPayload(
          bundle['identityKey'] as String,
          bundle['signedPreKey'] as String,
        ),
        keyPair: attacker,
      );
      bundle['signingKey'] = base64Encode(
        (await attacker.extractPublicKey()).bytes,
      );
      bundle['signature'] = base64Encode(signature.bytes);
      await KeyManager.verifyIdentityBundle(bundle);
      await expectLater(
        bob.sessions.decryptMessage('alice', jsonEncode(forged)),
        throwsA(anything),
      );
      expect(await bob.db.select(bob.db.backupState).get(), isEmpty);
      expect(await bob.sessions.decryptMessage('alice', original), 'authentic');
    },
  );
  test(
    'repeated authenticated handshakes keep bounded archived state',
    () async {
      final alice = await TestDevice.create('alice');
      final bob = await TestDevice.create('bob');
      addTearDown(alice.close);
      addTearDown(bob.close);
      for (var i = 0; i < 18; i++) {
        await alice.sessions.initiateSession('bob', await bob.keyBundle());
      }
      expect(
        (await alice.db.select(alice.db.signalSessions).get()).length,
        lessThanOrEqualTo(17),
      );
      final envelope = await alice.sessions.encryptMessage(
        'bob',
        'still usable',
      );
      expect(
        await bob.sessions.decryptMessage('alice', envelope),
        'still usable',
      );
    },
  );
  test(
    'forged session routing and replay do not overwrite accepted state',
    () async {
      final alice = await TestDevice.create('alice');
      final bob = await TestDevice.create('bob');
      addTearDown(alice.close);
      addTearDown(bob.close);
      await alice.sessions.initiateSession('bob', await bob.keyBundle());
      final original = await alice.sessions.encryptMessage('bob', 'authentic');
      final forged = jsonDecode(original) as Map<String, dynamic>;
      forged['sid'] = '0' * 64;
      await expectLater(
        bob.sessions.decryptMessage('alice', jsonEncode(forged)),
        throwsStateError,
      );
      expect(await bob.db.select(bob.db.signalSessions).get(), isEmpty);
      expect(await bob.sessions.decryptMessage('alice', original), 'authentic');
      await expectLater(
        bob.sessions.decryptMessage('alice', original),
        throwsA(anything),
      );
      final next = await alice.sessions.encryptMessage('bob', 'after replay');
      expect(await bob.sessions.decryptMessage('alice', next), 'after replay');
    },
  );
  test(
    'simultaneous first sends decrypt and converge while delayed messages survive',
    () async {
      final alice = await TestDevice.create('alice');
      final bob = await TestDevice.create('bob');
      addTearDown(alice.close);
      addTearDown(bob.close);
      await alice.sessions.initiateSession('bob', await bob.keyBundle());
      await bob.sessions.initiateSession('alice', await alice.keyBundle());
      final a1 = await alice.sessions.encryptMessage('bob', 'alice first');
      final a2 = await alice.sessions.encryptMessage('bob', 'alice delayed');
      final b1 = await bob.sessions.encryptMessage('alice', 'bob first');
      final b2 = await bob.sessions.encryptMessage('alice', 'bob delayed');
      expect(await bob.sessions.decryptMessage('alice', a1), 'alice first');
      expect(await alice.sessions.decryptMessage('bob', b1), 'bob first');
      final a3 = await alice.sessions.encryptMessage('bob', 'alice next');
      final b3 = await bob.sessions.encryptMessage('alice', 'bob next');
      expect(jsonDecode(a3)['sid'], jsonDecode(b3)['sid']);
      expect(await bob.sessions.decryptMessage('alice', a3), 'alice next');
      expect(await alice.sessions.decryptMessage('bob', b3), 'bob next');
      expect(await bob.sessions.decryptMessage('alice', a2), 'alice delayed');
      expect(await alice.sessions.decryptMessage('bob', b2), 'bob delayed');
    },
  );
  test(
    'failed initial ciphertext never pins a peer and valid retry succeeds',
    () async {
      final alice = await TestDevice.create('alice');
      final bob = await TestDevice.create('bob');
      addTearDown(alice.close);
      addTearDown(bob.close);
      await alice.sessions.initiateSession('bob', await bob.keyBundle());
      final original = await alice.sessions.encryptMessage('bob', 'authentic');
      final tampered = jsonDecode(original) as Map<String, dynamic>;
      final bytes = base64Decode(tampered['c'] as String);
      bytes[bytes.length - 1] ^= 1;
      tampered['c'] = base64Encode(bytes);
      await expectLater(
        bob.sessions.decryptMessage('alice', jsonEncode(tampered)),
        throwsA(anything),
      );
      expect(await bob.db.select(bob.db.backupState).get(), isEmpty);
      expect(await bob.sessions.decryptMessage('alice', original), 'authentic');
    },
  );
  test(
    'tampered signed prekey is rejected before session state is persisted',
    () async {
      final alice = await TestDevice.create('alice');
      final bob = await TestDevice.create('bob');
      final mallory = await TestDevice.create('mallory');
      addTearDown(alice.close);
      addTearDown(bob.close);
      addTearDown(mallory.close);
      final bundle = await bob.keyBundle();
      bundle['signedPreKey'] = (await mallory.keys
          .getOrCreateSignedPreKey())['publicKey'];
      await expectLater(
        alice.sessions.initiateSession('bob', bundle),
        throwsStateError,
      );
      expect(await alice.db.select(alice.db.signalSessions).get(), isEmpty);
    },
  );

  test('new signing identity for pinned peer is rejected', () async {
    final alice = await TestDevice.create('alice');
    final bob = await TestDevice.create('bob');
    final mallory = await TestDevice.create('mallory');
    addTearDown(alice.close);
    addTearDown(bob.close);
    addTearDown(mallory.close);
    await alice.sessions.initiateSession('bob', await bob.keyBundle());
    await expectLater(
      alice.sessions.initiateSession('bob', await mallory.keyBundle()),
      throwsStateError,
    );
  });
}
