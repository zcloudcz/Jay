import 'dart:async';

import 'package:calltype_core/devices/device_directory.dart';
import 'package:calltype_core/messaging/contact_sync.dart';
import 'package:drift/drift.dart';

import 'package:calltype_core/storage/database.dart';
import '../chat/chat_deletion.dart' show wasChatDeleted;
import '../devices/device_service.dart' show OwnLinkEvent;
import '../devices/own_device_sender.dart';

/// BackupState key prefix of a contact removed on another own device:
/// `contact-removed:<deviceId>` = ms. Kept so a late, older upsert cannot
/// bring the contact back (same reason as the reaction tombstones).
const contactRemovedPrefix = 'contact-removed:';

/// BackupState key prefix: an own device that has sent us any own-device
/// sync message, i.e. runs an app that understands them.
const ownSyncSeenPrefix = 'ownsync-seen:';

/// One own-device control message the inbox accepted (sender verified as
/// one of our devices), for the services that act on it.
class OwnControlMessage {
  const OwnControlMessage({
    required this.type,
    required this.body,
    required this.senderDeviceId,
  });

  final String type;
  final String body;
  final String senderDeviceId;
}

/// Applies a received `contact-sync` (spec 2026-11-08-contact-sync).
/// Returns whether a contact or conversation changed. Runs inside the
/// inbox transaction.
Future<bool> applyContactSync(AppDatabase db, ContactSyncPayload payload) =>
    switch (payload.op) {
      ContactSyncOp.upsert => applySyncedContacts(db, payload.contacts),
      ContactSyncOp.snapshot => () async {
        final contacts = await applySyncedContacts(db, payload.contacts);
        final conversations = await applySyncedConversations(
          db,
          payload.conversations,
        );
        return contacts || conversations;
      }(),
      ContactSyncOp.remove => _applyRemove(
        db,
        payload.removedDeviceIds,
        payload.changedAt,
      ),
    };

/// Last writer wins per contact name ([remoteNameWins]); a contact unknown
/// here is inserted unless a newer removal is remembered. `userHandle` and
/// `isBot` are taken only for a new contact (they come from the server
/// lookup and do not change).
Future<bool> applySyncedContacts(
  AppDatabase db,
  List<SyncedContact> contacts,
) async {
  var changed = false;
  // One read instead of one per entry: a snapshot carries up to 2000.
  final known = {
    for (final c in await db.select(db.contacts).get()) c.deviceId: c,
  };
  for (final entry in contacts) {
    final local = known[entry.deviceId];
    if (local == null) {
      final removedAt = await _removedAt(db, entry.deviceId);
      final writtenAt =
          entry.nameChangedAt > entry.addedAt.millisecondsSinceEpoch
          ? entry.nameChangedAt
          : entry.addedAt.millisecondsSinceEpoch;
      if (removedAt != null && removedAt >= writtenAt) continue;
      final inserted = await db
          .into(db.contacts)
          .insertReturningOrNull(
            ContactsCompanion.insert(
              deviceId: entry.deviceId,
              userHandle: entry.userHandle,
              displayName: Value(entry.displayName),
              // Identity keys are never synced; like a contact added by
              // handle, the key arrives with the first session.
              identityKey: Uint8List(0),
              addedAt: entry.addedAt,
              isBot: Value(entry.isBot),
              nameChangedAt: Value(entry.nameChangedAt),
            ),
            mode: InsertMode.insertOrIgnore,
          );
      if (inserted != null) known[entry.deviceId] = inserted;
      changed = true;
      continue;
    }
    if (!remoteNameWins(
      localAt: local.nameChangedAt,
      localName: local.displayName,
      remoteAt: entry.nameChangedAt,
      remoteName: entry.displayName,
    )) {
      continue;
    }
    await (db.update(
      db.contacts,
    )..where((c) => c.deviceId.equals(entry.deviceId))).write(
      ContactsCompanion(
        displayName: Value(entry.displayName),
        nameChangedAt: Value(entry.nameChangedAt),
      ),
    );
    known[entry.deviceId] = local.copyWith(
      displayName: Value(entry.displayName),
      nameChangedAt: entry.nameChangedAt,
    );
    changed = true;
  }
  return changed;
}

/// Conversation headers of a snapshot: an unknown one is inserted (without
/// messages, unread 0) unless it was deleted here (a header has no time, so
/// an older snapshot must not bring a deleted chat back, spec
/// 2026-11-09-delete-chats-contacts); a known one only gains what it lacks
/// (a title, the organization), so a snapshot never overwrites local state.
Future<bool> applySyncedConversations(
  AppDatabase db,
  List<SyncedConversation> conversations,
) async {
  var changed = false;
  for (final entry in conversations) {
    final local = await (db.select(
      db.conversations,
    )..where((c) => c.id.equals(entry.id))).getSingleOrNull();
    if (local == null) {
      if (await wasChatDeleted(db, entry.id)) continue;
      await db
          .into(db.conversations)
          .insert(
            ConversationsCompanion.insert(
              id: entry.id,
              type: entry.type,
              title: Value(entry.title),
              organizationId: Value(entry.organizationId),
              organizationName: Value(entry.organizationName),
            ),
            mode: InsertMode.insertOrIgnore,
          );
      changed = true;
      continue;
    }
    if (local.type != entry.type) continue;
    final update = ConversationsCompanion(
      title: local.title == null && entry.title != null
          ? Value(entry.title)
          : const Value.absent(),
      organizationId:
          local.organizationId == null && entry.organizationId != null
          ? Value(entry.organizationId)
          : const Value.absent(),
      organizationName:
          local.organizationName == null && entry.organizationName != null
          ? Value(entry.organizationName)
          : const Value.absent(),
    );
    if (!update.title.present &&
        !update.organizationId.present &&
        !update.organizationName.present) {
      continue;
    }
    await (db.update(
      db.conversations,
    )..where((c) => c.id.equals(entry.id))).write(update);
    changed = true;
  }
  return changed;
}

Future<bool> _applyRemove(
  AppDatabase db,
  List<String> deviceIds,
  int changedAt,
) async {
  var changed = false;
  for (final id in deviceIds) {
    final previous = await _removedAt(db, id);
    if (previous != null && previous >= changedAt) continue;
    await db
        .into(db.backupState)
        .insertOnConflictUpdate(
          BackupStateCompanion.insert(
            key: '$contactRemovedPrefix$id',
            value: '$changedAt',
          ),
        );
    final local = await (db.select(
      db.contacts,
    )..where((c) => c.deviceId.equals(id))).getSingleOrNull();
    // A rename after the removal (on a device that had not seen it yet)
    // keeps the contact: the newer change wins, like for names.
    if (local == null || local.nameChangedAt > changedAt) continue;
    await (db.delete(db.contacts)..where((c) => c.deviceId.equals(id))).go();
    changed = true;
  }
  return changed;
}

Future<int?> _removedAt(AppDatabase db, String deviceId) async {
  final row =
      await (db.select(db.backupState)
            ..where((s) => s.key.equals('$contactRemovedPrefix$deviceId')))
          .getSingleOrNull();
  return row == null ? null : int.tryParse(row.value);
}

SyncedContact syncedContactOf(Contact c) => SyncedContact(
  deviceId: c.deviceId,
  userHandle: c.userHandle,
  displayName: c.displayName,
  isBot: c.isBot,
  addedAt: c.addedAt,
  nameChangedAt: c.nameChangedAt,
);

/// Keeps the contacts of all own devices in step (spec
/// 2026-11-08-contact-sync): a snapshot after linking, one upsert per local
/// add or rename, and the answer to a companion's request.
class ContactSyncService {
  ContactSyncService({
    required AppDatabase database,
    required OwnDeviceSender sender,
    required DeviceDirectory Function() directory,
    required Stream<OwnControlMessage> controls,
    Stream<OwnLinkEvent>? linkEvents,
  }) : _db = database,
       _sender = sender,
       _directory = directory,
       _controls = controls,
       _linkEvents = linkEvents;

  final AppDatabase _db;
  final OwnDeviceSender _sender;
  final DeviceDirectory Function() _directory;
  final Stream<OwnControlMessage> _controls;
  final Stream<OwnLinkEvent>? _linkEvents;
  final _subscriptions = <StreamSubscription<Object?>>[];

  void start() {
    if (_subscriptions.isNotEmpty) return;
    _subscriptions.add(
      _controls.listen((message) {
        // Only the primary answers, so a request does not make every
        // companion send the same snapshot.
        if (message.type == contactSyncRequestType &&
            !_directory().isCompanion) {
          unawaited(sendSnapshot());
        }
      }),
    );
    final links = _linkEvents;
    if (links != null) {
      _subscriptions.add(
        links.listen((event) {
          switch (event) {
            case OwnLinkEvent.companionsAdded:
              unawaited(sendSnapshot());
            case OwnLinkEvent.becameCompanion:
              // Repairs a snapshot the primary sent before this device knew
              // it was linked (it was dropped as not ours then).
              unawaited(requestSnapshot());
          }
        }),
      );
    }
  }

  /// Every contact and every conversation header, split as the limits
  /// need. False when there is no other own device or a part failed.
  Future<bool> sendSnapshot() async {
    final contacts = await _db.select(_db.contacts).get();
    final conversations = await _db.select(_db.conversations).get();
    var ok = true;
    for (final part in ContactSyncPayload.snapshots(
      [for (final c in contacts) syncedContactOf(c)],
      [
        for (final c in conversations)
          SyncedConversation(
            id: c.id,
            type: c.type,
            title: c.title,
            organizationId: c.organizationId,
            organizationName: c.organizationName,
          ),
      ],
    )) {
      ok = await _sender.send(contactSyncType, part.encode()) && ok;
    }
    return ok;
  }

  Future<bool> requestSnapshot() => _sender.send(contactSyncRequestType, '{}');

  /// After a local add or rename of [deviceId].
  Future<bool> contactChanged(String deviceId) async {
    final contact = await (_db.select(
      _db.contacts,
    )..where((c) => c.deviceId.equals(deviceId))).getSingleOrNull();
    if (contact == null) return false;
    return _sender.send(
      contactSyncType,
      ContactSyncPayload.upsert([syncedContactOf(contact)]).encode(),
    );
  }

  /// After a local removal of [deviceId] at [removedAt] (ms, spec
  /// 2026-11-09-delete-chats-contacts D4). False when there is no other own
  /// device or the send is still queued.
  Future<bool> contactRemoved(String deviceId, int removedAt) async {
    if ((await _sender.otherDevices()).isEmpty) return false;
    return _sender.send(
      contactSyncType,
      ContactSyncPayload.remove([deviceId], removedAt).encode(),
    );
  }

  /// Our other devices in the verified own list.
  Future<List<String>> otherDevices() => _sender.otherDevices();

  /// Own devices that never sent us an own-device sync message: probably
  /// an old app that cannot apply them (best effort, spec Compatibility).
  Future<List<String>> silentDevices() async {
    final seen = {
      for (final row in await (_db.select(
        _db.backupState,
      )..where((s) => s.key.like('$ownSyncSeenPrefix%'))).get())
        row.key.substring(ownSyncSeenPrefix.length),
    };
    return [
      for (final d in await _sender.otherDevices())
        if (!seen.contains(d)) d,
    ];
  }

  Future<void> dispose() async {
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
  }
}
