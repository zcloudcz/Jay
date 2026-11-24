import 'dart:async';
import 'dart:convert';

import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/network/user_safety_api.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

/// `backup_state` key prefix of the cached block list (spec 2026-11-14-go-live
/// D5): one row per blocked identity, value = JSON of handle and name.
const blockKeyPrefix = 'block:';

/// The people this identity blocked (spec 2026-11-14-go-live A7/A8).
///
/// The SERVER enforces a block (it drops their messages, calls and typing to
/// every device of ours), so this controller only mirrors the server list:
/// [refresh] replaces the cache on every hub connect, and the cache in the
/// drift `backup_state` table keeps the chat list right while offline. Ids
/// are identities (primary device ids, lower case), the same ids 1:1
/// conversations use.
class BlockController extends ChangeNotifier {
  BlockController({required AppDatabase database, required ApiClient apiClient})
    : _db = database,
      _api = apiClient;

  final AppDatabase _db;
  final ApiClient _api;
  Map<String, BlockedUser> _blocked = {};
  bool _disposed = false;

  /// Blocked people, newest first.
  List<BlockedUser> get blocked => _blocked.values.toList()
    ..sort(
      (a, b) =>
          (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0)),
    );

  bool isBlocked(String id) => _blocked.containsKey(id.toLowerCase());

  /// Loads the cached list (no network).
  Future<void> load() async {
    final rows = await (_db.select(
      _db.backupState,
    )..where((s) => s.key.like('$blockKeyPrefix%'))).get();
    final next = <String, BlockedUser>{};
    for (final row in rows) {
      final id = row.key.substring(blockKeyPrefix.length);
      try {
        final json = jsonDecode(row.value);
        next[id] =
            BlockedUser.tryParse({...json as Map, 'deviceId': id}) ??
            BlockedUser(deviceId: id, userHandle: '');
      } catch (_) {
        next[id] = BlockedUser(deviceId: id, userHandle: '');
      }
    }
    _blocked = next;
    _notify();
  }

  /// Replaces the cache with the server's list; false when that failed.
  /// Errors (offline, an old server without `/blocks`) leave the cache as
  /// it is.
  Future<bool> refresh() async {
    final List<BlockedUser> users;
    try {
      users = await _api.getBlockedUsers();
    } catch (_) {
      return false;
    }
    await _store(users);
    return true;
  }

  /// Blocks [id] on the server, then refreshes, because the server keys the
  /// block by IDENTITY: [id] may be a companion device of that person.
  /// Throws when the server refused; nothing changes locally then.
  Future<void> block(String id) async {
    await _api.blockUser(id);
    // A failed refresh: still hide the chat at once, under the id we know.
    if (!await refresh() && !isBlocked(id)) {
      await _store([
        ..._blocked.values,
        BlockedUser(
          deviceId: id.toLowerCase(),
          userHandle: '',
          createdAt: DateTime.now().toUtc(),
        ),
      ]);
    }
  }

  Future<void> unblock(String id) async {
    await _api.unblockUser(id);
    await _store([
      for (final user in _blocked.values)
        if (user.deviceId != id.toLowerCase()) user,
    ]);
  }

  /// Account deletion: forget everything (the rows go with the wipe).
  void clear() {
    _blocked = {};
    _notify();
  }

  Future<void> _store(List<BlockedUser> users) async {
    await _db.transaction(() async {
      await (_db.delete(
        _db.backupState,
      )..where((s) => s.key.like('$blockKeyPrefix%'))).go();
      for (final user in users) {
        await _db
            .into(_db.backupState)
            .insertOnConflictUpdate(
              BackupStateCompanion.insert(
                key: '$blockKeyPrefix${user.deviceId}',
                value: jsonEncode({
                  'userHandle': user.userHandle,
                  'displayName': ?user.displayName,
                  'isBot': user.isBot,
                  'createdAt': ?user.createdAt?.toUtc().toIso8601String(),
                }),
              ),
            );
      }
    });
    _blocked = {for (final user in users) user.deviceId: user};
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
