import 'dart:typed_data';

import 'package:calltype_core/crypto/memory_protocol_store.dart';
import 'package:calltype_core/crypto/protocol_store.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:calltype_core/storage/drift_protocol_store.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:test/test.dart';

/// The same contract for both ProtocolStore implementations, so tests that
/// run the ratchet over MemoryProtocolStore say something about the drift
/// store the client really uses. The drift-only group pins the exact rows
/// and keys, which must not change (no schema change, old backups).
void main() {
  final stores =
      <
        String,
        Future<({ProtocolStore store, Future<void> Function() close})>
        Function()
      >{
        'memory': () async =>
            (store: MemoryProtocolStore(), close: () async {}),
        'drift': () async {
          final db = AppDatabase(NativeDatabase.memory());
          return (store: DriftProtocolStore(db), close: db.close);
        },
      };

  for (final MapEntry(key: name, value: open) in stores.entries) {
    group(name, () {
      late ProtocolStore store;
      late Future<void> Function() close;
      setUp(() async {
        final opened = await open();
        store = opened.store;
        close = opened.close;
      });
      tearDown(() => close());

      Uint8List b(List<int> v) => Uint8List.fromList(v);

      test('sessions: save, load, list by prefix, delete', () async {
        await store.saveSession('peer', b([1]));
        await store.saveSession('peer:aa', b([2]));
        await store.saveSession('peer:bb', b([3]));
        await store.saveSession('other:aa', b([4]));
        await store.saveSession('peer', b([5]));
        expect(await store.loadSession('peer'), [5]);
        expect(await store.loadSession('missing'), isNull);
        final listed = await store.listSessions('peer:');
        expect(listed.map((r) => r.address).toSet(), {'peer:aa', 'peer:bb'});
        await store.deleteSessions(['peer:aa', 'unknown']);
        await store.deleteSessions([]);
        expect(await store.loadSession('peer:aa'), isNull);
        expect(await store.loadSession('peer:bb'), [3]);
      });

      test('transaction rolls back every kind of write on error', () async {
        await expectLater(
          store.transaction(() async {
            await store.saveSession('peer', b([1]));
            await store.pinIdentity('peer', 'ik|sk');
            await store.markPreKeyConsumed(7, 'peer');
            // Nested transaction joins the outer one.
            await store.transaction(() => store.saveSession('peer:x', b([2])));
            throw StateError('crash');
          }),
          throwsStateError,
        );
        expect(await store.loadSession('peer'), isNull);
        expect(await store.loadSession('peer:x'), isNull);
        expect(await store.pinnedIdentity('peer'), isNull);
        expect(await store.isPreKeyConsumed(7), isFalse);
        expect(await store.transaction(() async => 42), 42);
      });

      test('identity pins and pre-key markers', () async {
        expect(await store.pinnedIdentity('peer'), isNull);
        await store.pinIdentity('peer', 'ik|sk');
        await store.pinIdentity('peer', 'ik2|sk2');
        expect(await store.pinnedIdentity('peer'), 'ik2|sk2');
        await store.markPreKeyConsumed(3, 'peer');
        await store.markPreKeyConsumed(12, 'other');
        expect(await store.isPreKeyConsumed(3), isTrue);
        expect(await store.isPreKeyConsumed(4), isFalse);
        expect((await store.consumedPreKeyIds()).toSet(), {3, 12});
      });

      test('contact key is only written for an existing contact', () async {
        await store.setContactIdentityKey('stranger', b([9]));
        expect(await store.contactIdentityKey('stranger'), isNull);
      });
    });
  }

  group('drift rows stay exactly as before the split', () {
    late AppDatabase db;
    late DriftProtocolStore store;
    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      store = DriftProtocolStore(db);
    });
    tearDown(() => db.close());

    test(
      'pins, markers and contact keys use the old tables and keys',
      () async {
        await db
            .into(db.contacts)
            .insert(
              ContactsCompanion.insert(
                deviceId: 'peer',
                userHandle: 'CT-PEER-0001',
                identityKey: Uint8List(0),
                addedAt: DateTime.utc(2026),
              ),
            );
        expect(await store.contactIdentityKey('peer'), isEmpty);
        await store.setContactIdentityKey('peer', Uint8List.fromList([1, 2]));
        await store.pinIdentity('peer', 'ik|sk');
        await store.markPreKeyConsumed(5, 'peer');
        await store.saveSession('peer:sid', Uint8List.fromList([7]));

        final state = {
          for (final r in await db.select(db.backupState).get()) r.key: r.value,
        };
        expect(state, {
          'peer_identity:peer': 'ik|sk',
          'consumed_prekey:5': 'peer',
        });
        final contact = await (db.select(
          db.contacts,
        )..where((c) => c.deviceId.equals('peer'))).getSingle();
        expect(contact.identityKey, [1, 2]);
        final sessions = await db.select(db.signalSessions).get();
        expect(sessions.single.address, 'peer:sid');
        expect(sessions.single.sessionData, [7]);
      },
    );
  });
}
