import 'package:calltype/core/storage/secure_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

const _legacy = 'unlocked';
const _newAcc = 'first_unlock_this_device';

/// Models the iOS keychain the way flutter_secure_storage_darwin 0.3.x uses
/// it (FlutterSecureStorage.swift): an item is unique per account (key), the
/// accessibility is a stored attribute, and every query — read, readAll,
/// containsKey, and the add inside write — MATCHES on it. Only delete ignores
/// it. The plugin's stock test platform ignores options entirely, so it
/// could not show why the migration is needed.
class FakeKeychain extends FlutterSecureStoragePlatform {
  final items = <String, ({String value, String acc})>{};

  /// Locked phone: `unlocked` items are unreadable (errSecInteractionNotAllowed).
  bool locked = false;

  /// Throws on the n-th operation (0-based) to simulate the process dying.
  int? failAt;
  int _ops = 0;

  void _tick() {
    if (failAt != null && _ops++ == failAt) {
      throw PlatformException(code: 'simulated-crash');
    }
  }

  static String _acc(Map<String, String> o) => o['accessibility'] ?? _legacy;

  void _checkAccessible(String acc) {
    if (locked && acc == _legacy) {
      throw PlatformException(
        code: 'Unexpected security result code',
        details: -25308,
      );
    }
  }

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    _tick();
    final item = items[key];
    if (item == null || item.acc != _acc(options)) return null;
    _checkAccessible(item.acc);
    return item.value;
  }

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    _tick();
    final acc = _acc(options);
    final existing = items[key];
    if (existing != null && existing.acc != acc) {
      // containsKey (with the new accessibility) said no, SecItemAdd collides.
      throw PlatformException(
        code: 'Unexpected security result code',
        details: -25299,
      );
    }
    _checkAccessible(acc);
    items[key] = (value: value, acc: acc);
  }

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async {
    _tick();
    items.remove(key);
  }

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async {
    _tick();
    final acc = _acc(options);
    final matching = items.entries.where((e) => e.value.acc == acc);
    if (matching.isNotEmpty) _checkAccessible(acc);
    return {for (final e in matching) e.key: e.value.value};
  }

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async => items[key]?.acc == _acc(options);

  @override
  Future<void> deleteAll({required Map<String, String> options}) async {
    items.clear();
  }
}

Map<String, ({String value, String acc})> _legacyItems() => {
  'ct_device_id': (value: 'dev-1', acc: _legacy),
  'ct_device_secret': (value: 'secret-1', acc: _legacy),
  'ct_identity_private_key': (value: 'priv', acc: _legacy),
  'ct_one_time_prekeys': (value: '[1,2,3]', acc: _legacy),
  'ct_pin_hash': (value: 'hash', acc: _legacy),
};

void main() {
  late FakeKeychain keychain;

  setUp(() {
    keychain = FakeKeychain();
    FlutterSecureStoragePlatform.instance = keychain;
    // flutter_secure_storage picks iOptions only when the target is iOS.
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  SecureStorage ios() => SecureStorage(migrateAppleKeychain: true);

  group('iOS keychain accessibility', () {
    test('new writes use first_unlock_this_device', () async {
      await ios().setDeviceId('dev-1');
      expect(keychain.items['ct_device_id']!.acc, _newAcc);
    });

    test('migration rewrites every legacy item and keeps its value', () async {
      keychain.items.addAll(_legacyItems());
      final storage = ios();

      await storage.migrateKeychainAccessibility();

      for (final e in _legacyItems().entries) {
        expect(keychain.items[e.key], (value: e.value.value, acc: _newAcc));
      }
      expect(
        keychain.items.keys.where(
          (k) => k.startsWith(SecureStorage.migrationBackupPrefix),
        ),
        isEmpty,
      );
      expect(await storage.getDeviceId(), 'dev-1');
      expect(await storage.getDeviceSecret(), 'secret-1');
    });

    test('migration is idempotent', () async {
      keychain.items.addAll(_legacyItems());
      final storage = ios();
      await storage.migrateKeychainAccessibility();
      final after = Map.of(keychain.items);
      await storage.migrateKeychainAccessibility();
      expect(keychain.items, after);
    });

    test(
      'a crash at any step loses nothing once the next start migrates',
      () async {
        // Count the operations of one clean run, then crash at each of them.
        final probe = FakeKeychain()..items.addAll(_legacyItems());
        FlutterSecureStoragePlatform.instance = probe;
        probe.failAt = -1; // count only
        await ios().migrateKeychainAccessibility();
        final totalOps = probe._ops;
        expect(totalOps, greaterThan(10));

        for (var crashAt = 0; crashAt < totalOps; crashAt++) {
          final kc = FakeKeychain()..items.addAll(_legacyItems());
          FlutterSecureStoragePlatform.instance = kc;
          kc.failAt = crashAt;
          await ios().migrateKeychainAccessibility(); // dies mid-way, no throw
          kc.failAt = null; // "next app start"
          final storage = ios();
          await storage.migrateKeychainAccessibility();

          for (final e in _legacyItems().entries) {
            expect(
              kc.items[e.key],
              (value: e.value.value, acc: _newAcc),
              reason: 'crash at op $crashAt lost or kept ${e.key} wrong',
            );
          }
          expect(
            kc.items.keys.where(
              (k) => k.startsWith(SecureStorage.migrationBackupPrefix),
            ),
            isEmpty,
            reason: 'crash at op $crashAt left a backup copy',
          );
        }
      },
    );

    test('a locked phone defers the migration without throwing', () async {
      keychain.items.addAll(_legacyItems());
      keychain.locked = true;
      final storage = ios();

      await storage.migrateKeychainAccessibility();
      expect(keychain.items['ct_device_id']!.acc, _legacy);

      keychain.locked = false; // next start, unlocked
      await storage.migrateKeychainAccessibility();
      expect(keychain.items['ct_device_id']!.acc, _newAcc);
    });

    test('read falls back to a not-yet-migrated legacy item', () async {
      keychain.items['ct_device_id'] = (value: 'dev-1', acc: _legacy);
      expect(await ios().getDeviceId(), 'dev-1');
    });

    test(
      'a locked legacy read throws instead of answering "no device"',
      () async {
        // null would send the app into onboarding and register a 2nd identity.
        keychain.items['ct_device_id'] = (value: 'dev-1', acc: _legacy);
        keychain.locked = true;
        expect(ios().getDeviceId(), throwsA(isA<PlatformException>()));
      },
    );

    test('write over a legacy item replaces it instead of failing', () async {
      keychain.items['ct_one_time_prekeys'] = (value: 'old', acc: _legacy);
      await ios().write('ct_one_time_prekeys', 'new');
      expect(keychain.items['ct_one_time_prekeys'], (
        value: 'new',
        acc: _newAcc,
      ));
    });

    test('other platforms never touch legacy items', () async {
      keychain.items.addAll(_legacyItems());
      final storage = SecureStorage(migrateAppleKeychain: false);
      await storage.migrateKeychainAccessibility();
      expect(keychain.items, _legacyItems());
    });
  });

  group('account and backup secrets (D §4.1 point 7)', () {
    setUp(() {
      debugDefaultTargetPlatformOverride = null;
      FlutterSecureStorage.setMockInitialValues({});
    });

    test('backup key, salt and account e-mail round-trip', () async {
      final storage = SecureStorage();
      await storage.setBackupKey('a2V5');
      await storage.setBackupSalt('c2FsdA==');
      await storage.setAccountEmail('user@example.com');

      expect(await storage.getBackupKey(), 'a2V5');
      expect(await storage.getBackupSalt(), 'c2FsdA==');
      expect(await storage.getAccountEmail(), 'user@example.com');
      expect(await storage.read('ct_backup_key_v1'), 'a2V5');
      expect(await storage.read('ct_backup_salt_v1'), 'c2FsdA==');
      expect(await storage.read('ct_account_email'), 'user@example.com');

      await storage.deleteBackupKey();
      expect(await storage.getBackupKey(), isNull);
    });

    test('clearAccount forgets the account but keeps the device', () async {
      final storage = SecureStorage();
      await storage.setDeviceId('dev-1');
      await storage.setDeviceSecret('secret-1');
      await storage.setAccountId('acc-1');
      await storage.setAccountEmail('user@example.com');
      await storage.setBackupKey('a2V5');
      await storage.setBackupSalt('c2FsdA==');

      await storage.clearAccount();

      expect(await storage.getAccountId(), isNull);
      expect(await storage.getAccountEmail(), isNull);
      expect(await storage.getBackupKey(), isNull);
      expect(await storage.getBackupSalt(), isNull);
      expect(await storage.getDeviceId(), 'dev-1');
      expect(await storage.getDeviceSecret(), 'secret-1');
    });

    test('deleteAll wipes everything', () async {
      final storage = SecureStorage();
      await storage.setDeviceId('dev-1');
      await storage.setAccountId('acc-1');
      await storage.deleteAll();
      expect(await storage.getDeviceId(), isNull);
      expect(await storage.getAccountId(), isNull);
    });
  });
}
