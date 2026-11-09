import 'package:calltype_protocol/crypto/key_manager.dart';
import 'package:test/test.dart';

import '../helpers/test_device.dart' show InMemorySecureStorage;

/// One-time pre-key replenishment (spec 2026-11-09-bot-access A6).
void main() {
  test('new one-time pre-keys continue after the initial batch and never '
      'reuse an id, even after keys were consumed', () async {
    final keys = KeyManager(secureStorage: InMemorySecureStorage());
    final initial = await keys.getOrCreateOneTimePreKeys();
    expect(initial.last['keyId'], KeyManager.initialOneTimePreKeyCount);

    // The highest keys are used up: max(existing) + 1 would reuse 100.
    await keys.consumeOneTimePreKey(100);
    await keys.consumeOneTimePreKey(99);
    final first = await keys.createOneTimePreKeys(3);
    expect([for (final k in first) k['keyId']], [101, 102, 103]);
    await keys.consumeOneTimePreKey(103);
    final second = await keys.createOneTimePreKeys(2);
    expect([for (final k in second) k['keyId']], [104, 105]);

    // New keys are stored with their private halves and can be used.
    expect(await keys.peekOneTimePreKey(104), second.first['privateKey']);
    expect(await keys.peekOneTimePreKey(1), isNotNull);
  });

  test('the local store is capped; the oldest keys are dropped', () async {
    final keys = KeyManager(secureStorage: InMemorySecureStorage());
    await keys.getOrCreateOneTimePreKeys();
    final extra = KeyManager.maxStoredOneTimePreKeys;
    await keys.createOneTimePreKeys(extra);
    final all = await keys.getOrCreateOneTimePreKeys();
    expect(all, hasLength(KeyManager.maxStoredOneTimePreKeys));
    expect(await keys.peekOneTimePreKey(1), isNull);
    expect(all.last['keyId'], KeyManager.initialOneTimePreKeyCount + extra);
  });
}
