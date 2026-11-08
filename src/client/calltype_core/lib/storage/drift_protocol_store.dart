import 'package:drift/drift.dart';

import 'package:calltype_protocol/store/protocol_store.dart';
import 'database.dart';

/// [ProtocolStore] over the client's drift schema. Same tables, same keys
/// and same bytes the SessionManager wrote before it was decoupled from
/// drift, so existing databases and backups keep working without migration:
///
/// * sessions: `signal_sessions` (address -> JSON blob), active session
///   under `<peer>`, archives under `<peer>:<sid>`;
/// * identity pins: `backup_state` key `peer_identity:<peer>` with value
///   `identityKey|signingKey`, plus `contacts.identity_key`;
/// * one-time pre-key markers: `backup_state` key `consumed_prekey:<id>`
///   with the peer device id as value.
///
/// WHY it takes the app's [AppDatabase] and not its own connection:
/// [transaction] is drift's, so a caller that wraps `decryptMessage` and
/// its own inserts in `db.transaction` (the app inbox, calltype_bot) gets
/// the ratchet step and its rows committed together, as before.
class DriftProtocolStore implements ProtocolStore {
  DriftProtocolStore(this._db);

  final AppDatabase _db;

  static const _peerIdentityPrefix = 'peer_identity:';
  static const _consumedPreKeyPrefix = 'consumed_prekey:';

  @override
  Future<T> transaction<T>(Future<T> Function() action) =>
      _db.transaction(action);

  @override
  Future<Uint8List?> loadSession(String address) async {
    final row = await (_db.select(
      _db.signalSessions,
    )..where((s) => s.address.equals(address))).getSingleOrNull();
    return row?.sessionData;
  }

  @override
  Future<void> saveSession(String address, Uint8List data) => _db
      .into(_db.signalSessions)
      .insertOnConflictUpdate(
        SignalSessionsCompanion.insert(address: address, sessionData: data),
      );

  @override
  Future<List<({String address, Uint8List data})>> listSessions(
    String prefix,
  ) async {
    final rows = await (_db.select(
      _db.signalSessions,
    )..where((row) => row.address.like('$prefix%'))).get();
    return [for (final r in rows) (address: r.address, data: r.sessionData)];
  }

  @override
  Future<void> deleteSessions(List<String> addresses) async {
    if (addresses.isEmpty) return;
    await (_db.delete(
      _db.signalSessions,
    )..where((row) => row.address.isIn(addresses))).go();
  }

  @override
  Future<String?> pinnedIdentity(String peerDeviceId) async {
    final row =
        await (_db.select(_db.backupState)
              ..where((r) => r.key.equals('$_peerIdentityPrefix$peerDeviceId')))
            .getSingleOrNull();
    return row?.value;
  }

  @override
  Future<void> pinIdentity(String peerDeviceId, String fingerprint) => _db
      .into(_db.backupState)
      .insertOnConflictUpdate(
        BackupStateCompanion.insert(
          key: '$_peerIdentityPrefix$peerDeviceId',
          value: fingerprint,
        ),
      );

  @override
  Future<Uint8List?> contactIdentityKey(String peerDeviceId) async {
    final contact = await (_db.select(
      _db.contacts,
    )..where((r) => r.deviceId.equals(peerDeviceId))).getSingleOrNull();
    return contact?.identityKey;
  }

  @override
  Future<void> setContactIdentityKey(
    String peerDeviceId,
    Uint8List identityKey,
  ) =>
      (_db.update(_db.contacts)
            ..where((row) => row.deviceId.equals(peerDeviceId)))
          .write(ContactsCompanion(identityKey: Value(identityKey)));

  @override
  Future<bool> isPreKeyConsumed(int keyId) async {
    final row =
        await (_db.select(_db.backupState)
              ..where((row) => row.key.equals('$_consumedPreKeyPrefix$keyId')))
            .getSingleOrNull();
    return row != null;
  }

  @override
  Future<void> markPreKeyConsumed(int keyId, String peerDeviceId) => _db
      .into(_db.backupState)
      .insertOnConflictUpdate(
        BackupStateCompanion.insert(
          key: '$_consumedPreKeyPrefix$keyId',
          value: peerDeviceId,
        ),
      );

  @override
  Future<List<int>> consumedPreKeyIds() async {
    final rows = await (_db.select(
      _db.backupState,
    )..where((row) => row.key.like('$_consumedPreKeyPrefix%'))).get();
    return [for (final row in rows) int.parse(row.key.split(':').last)];
  }
}
