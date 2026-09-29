import 'package:calltype_core/crypto/safety_number.dart';
import 'package:calltype_core/crypto/session_manager.dart';
import 'package:test/test.dart';

import '../helpers/test_device.dart';

/// X0: the frozen S6 types exist and the only behaviour already live — the
/// typed exception — is still a StateError for every existing caller.
void main() {
  test('a changed identity throws IdentityChangedException (a StateError) '
      'with the pending change', () async {
    final alice = await TestDevice.create('alice');
    final bob = await TestDevice.create('bob');
    final bobReinstalled = await TestDevice.create('bob');
    addTearDown(() async {
      await alice.close();
      await bob.close();
      await bobReinstalled.close();
    });

    final original = await bob.keyBundle();
    await alice.sessions.initiateSession(bob.id, original);
    final changed = await bobReinstalled.keyBundle();

    Object? error;
    try {
      await alice.sessions.initiateSession(bob.id, changed);
    } catch (e) {
      error = e;
    }
    expect(error, isA<StateError>());
    expect(error, isA<IdentityChangedException>());
    final change = (error as IdentityChangedException).change;
    expect(change.peerDeviceId, bob.id);
    expect(change.direction, IdentityChangeDirection.outgoing);
    expect(change.previousIdentityKey, original['identityKey']);
    expect(change.newIdentityKey, changed['identityKey']);
    expect(change.previousSigningKey, original['signingKey']);
    expect(change.newSigningKey, changed['signingKey']);
  });

  test('PendingIdentityChange survives a JSON round trip', () {
    final change = PendingIdentityChange(
      peerDeviceId: 'p',
      previousIdentityKey: 'a',
      previousSigningKey: 'b',
      newIdentityKey: 'c',
      newSigningKey: 'd',
      detectedAt: DateTime.utc(2026, 9, 29, 10),
      direction: IdentityChangeDirection.incoming,
    );
    final back = PendingIdentityChange.fromJson(change.toJson());
    expect(back.toJson(), change.toJson());
  });

  test('stubs exist with the frozen signatures', () async {
    final device = await TestDevice.create('x');
    addTearDown(device.close);
    expect(device.sessions.identityChanges.isBroadcast, isTrue);
    expect(
      () => device.sessions.acceptIdentityChange('p'),
      throwsUnimplementedError,
    );
    expect(
      () => SafetyNumber.compute(
        local: const PartyIdentity(
          deviceId: 'a',
          identityKey: 'k',
          signingKey: 's',
        ),
        remote: const PartyIdentity(
          deviceId: 'b',
          identityKey: 'k',
          signingKey: 's',
        ),
      ),
      throwsUnimplementedError,
    );
    expect(SafetyNumberScanResult.values, hasLength(4));
  });
}
