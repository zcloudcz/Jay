import 'dart:convert';

import 'package:calltype_core/crypto/key_manager.dart';
import 'package:calltype_core/crypto/memory_protocol_store.dart';
import 'package:calltype_core/crypto/session_manager.dart';
import 'package:test/test.dart';

import '../helpers/test_device.dart' show InMemorySecureStorage;

/// The ratchet without any database: SessionManager over
/// MemoryProtocolStore. Proves the protocol is independent of drift and
/// pins down the store semantics the drift implementation must also have.
class _Device {
  _Device(this.id, this.secrets)
    : store = MemoryProtocolStore(),
      keys = KeyManager(secureStorage: secrets) {
    sessions = SessionManager(store: store, keyManager: keys);
  }

  final String id;
  final InMemorySecureStorage secrets;
  final MemoryProtocolStore store;
  final KeyManager keys;
  late final SessionManager sessions;

  Future<Map<String, dynamic>> bundle({int? oneTimeId = 1}) async {
    final otks = await keys.getOrCreateOneTimePreKeys();
    final otk = oneTimeId == null
        ? null
        : otks.firstWhere((k) => k['keyId'] == oneTimeId);
    return {
      ...await keys.getSignedIdentityBundle(),
      if (otk != null)
        'oneTimePreKey': {'keyId': otk['keyId'], 'publicKey': otk['publicKey']},
    };
  }
}

class _Crash implements Exception {}

void main() {
  late _Device alice;
  late _Device bob;

  setUp(() {
    alice = _Device('alice', InMemorySecureStorage());
    bob = _Device('bob', InMemorySecureStorage());
  });

  test(
    'pre-key message, replies and ratchet steps in both directions',
    () async {
      await alice.sessions.initiateSession(bob.id, await bob.bundle());
      final a0 = await alice.sessions.encryptMessage(bob.id, 'a0');
      expect(jsonDecode(a0)['t'], 'pk');
      expect(await bob.sessions.decryptMessage(alice.id, a0), 'a0');

      final rk = <String>{};
      for (var round = 0; round < 3; round++) {
        final b = await bob.sessions.encryptMessage(alice.id, 'b$round');
        rk.add(jsonDecode(b)['rk'] as String);
        expect(await alice.sessions.decryptMessage(bob.id, b), 'b$round');
        final a = await alice.sessions.encryptMessage(bob.id, 'a$round');
        expect(jsonDecode(a)['t'], 'm');
        rk.add(jsonDecode(a)['rk'] as String);
        expect(await bob.sessions.decryptMessage(alice.id, a), 'a$round');
      }
      // Every turn of the conversation used a fresh ratchet key.
      expect(rk, hasLength(6));
    },
  );

  test('out-of-order messages decrypt with stored skipped keys', () async {
    await alice.sessions.initiateSession(bob.id, await bob.bundle());
    await bob.sessions.decryptMessage(
      alice.id,
      await alice.sessions.encryptMessage(bob.id, 'hi'),
    );
    final b = [
      for (var i = 0; i < 4; i++)
        await bob.sessions.encryptMessage(alice.id, 'b$i'),
    ];
    for (final i in [3, 0, 2, 1]) {
      expect(await alice.sessions.decryptMessage(bob.id, b[i]), 'b$i');
    }
    // A consumed skipped key is gone: the same message cannot be read twice.
    await expectLater(
      alice.sessions.decryptMessage(bob.id, b[1]),
      throwsA(anything),
    );
  });

  test(
    'crash inside the caller transaction neither advances the ratchet nor '
    'consumes the one-time pre-key; the retry decrypts exactly once',
    () async {
      await alice.sessions.initiateSession(bob.id, await bob.bundle());
      final a0 = await alice.sessions.encryptMessage(bob.id, 'first');
      final seen = <String>[];

      // The caller's transaction: decrypt + its own "seen id" write, then a
      // crash before commit (as the app inbox and the bot do it).
      await expectLater(
        bob.store.transaction(() async {
          seen.add(
            await bob.sessions.decryptMessage(
              alice.id,
              a0,
              deferPreKeyCleanup: true,
            ),
          );
          throw _Crash();
        }),
        throwsA(isA<_Crash>()),
      );
      expect(bob.store.sessionAddresses, isEmpty);
      expect(await bob.store.consumedPreKeyIds(), isEmpty);
      expect(await bob.store.pinnedIdentity(alice.id), isNull);
      expect(await bob.keys.peekOneTimePreKey(1), isNotNull);

      // Redelivery after the crash: decrypts, commits once.
      final plain = await bob.store.transaction(
        () =>
            bob.sessions.decryptMessage(alice.id, a0, deferPreKeyCleanup: true),
      );
      await bob.sessions.finalizePreKeyCleanup();
      expect(plain, 'first');
      expect(await bob.store.consumedPreKeyIds(), [1]);
      expect(await bob.keys.peekOneTimePreKey(1), isNull);

      // A second redelivery after the commit is refused: the message key
      // is spent, so nothing is ever processed twice.
      await expectLater(
        bob.sessions.decryptMessage(alice.id, a0),
        throwsA(anything),
      );
      // And the session still works for the next message.
      final a1 = await alice.sessions.encryptMessage(bob.id, 'second');
      expect(await bob.sessions.decryptMessage(alice.id, a1), 'second');
    },
  );

  test('crash after a normal message keeps the chain where it was', () async {
    await alice.sessions.initiateSession(bob.id, await bob.bundle());
    await bob.sessions.decryptMessage(
      alice.id,
      await alice.sessions.encryptMessage(bob.id, 'setup'),
    );
    final before = await bob.store.loadSession(alice.id);
    final a1 = await alice.sessions.encryptMessage(bob.id, 'a1');
    await expectLater(
      bob.store.transaction(() async {
        await bob.sessions.decryptMessage(alice.id, a1);
        throw _Crash();
      }),
      throwsA(isA<_Crash>()),
    );
    expect(await bob.store.loadSession(alice.id), before);
    expect(await bob.sessions.decryptMessage(alice.id, a1), 'a1');
  });

  test(
    'replayed pre-key message is refused after the pre-key was consumed',
    () async {
      await alice.sessions.initiateSession(bob.id, await bob.bundle());
      final a0 = await alice.sessions.encryptMessage(bob.id, 'first');
      await bob.sessions.decryptMessage(alice.id, a0);
      // Bob lost his sessions but kept keys and markers: the marker refuses.
      final fresh = SessionManager(store: bob.store, keyManager: bob.keys);
      await bob.store.deleteSessions(bob.store.sessionAddresses.toList());
      await expectLater(
        fresh.decryptMessage(alice.id, a0),
        throwsA(isA<StateError>()),
      );
    },
  );

  test('a changed peer identity is rejected against the pin', () async {
    await alice.sessions.initiateSession(bob.id, await bob.bundle());
    expect(await alice.store.pinnedIdentity(bob.id), isNotNull);
    final impostor = _Device('bob', InMemorySecureStorage());
    await expectLater(
      alice.sessions.initiateSession(bob.id, await impostor.bundle()),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'the contact identity key is checked and updated only for contacts',
    () async {
      alice.store.addContact(bob.id);
      await alice.sessions.initiateSession(bob.id, await bob.bundle());
      expect(
        base64Encode((await alice.store.contactIdentityKey(bob.id))!),
        await bob.keys.getPublicIdentityKey(),
      );
      expect(await alice.store.contactIdentityKey('stranger'), isNull);
    },
  );
}
