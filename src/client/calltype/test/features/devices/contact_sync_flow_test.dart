import 'dart:convert';

import 'package:calltype/core/storage/database.dart';
import 'package:calltype/features/chat/message_inbox_service.dart';
import 'package:calltype/features/contacts/contact_sync.dart';
import 'package:calltype/features/contacts/contacts_controller.dart';
import 'package:calltype/features/devices/device_service.dart';
import 'package:calltype/features/devices/history_transfer.dart';
import 'package:calltype/features/devices/own_device_sender.dart';
import 'package:calltype/features/media/media_service.dart';
import 'package:calltype/features/media/media_store_memory.dart';
import 'package:calltype_core/crypto/device_list.dart';
import 'package:calltype_core/messaging/contact_sync.dart';
import 'package:calltype_core/messaging/history_transfer.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_multi_device_server.dart';
import '../../helpers/test_device.dart';
import '../media/media_fakes.dart';

/// Contact sync and history transfer end to end (spec
/// 2026-11-08-contact-sync): real databases, ratchets, inboxes, device
/// services and the media pipeline; only the hub and the media relay are
/// in-memory fakes. A has a phone (primary), a web and a second web; B is a
/// contact.
const phoneId = 'a0000000-0000-4000-8000-000000000001';
const webId = 'a0000000-0000-4000-8000-000000000002';
const web2Id = 'a0000000-0000-4000-8000-000000000003';
const bobId = 'b0000000-0000-4000-8000-000000000001';
const carolId = 'c0000000-0000-4000-8000-000000000001';

/// Flips one ciphertext byte when [tamper] is set: a relay (or attacker)
/// that hands out other bytes than were uploaded.
class _Relay extends FakeMediaRemote {
  bool tamper = false;

  @override
  Future<DateTime> complete(String id) async {
    final at = await super.complete(id);
    if (tamper) blobs[id]![3] ^= 1;
    return at;
  }
}

class _Node {
  _Node._(this.device, this.server, this.devices, _Relay relay)
    : hub = server.hubs[device.id]!,
      media = MediaService(
        remote: relay,
        store: MemoryMediaStore(),
        web: false,
      ) {
    inbox = MessageInboxService(
      database: device.db,
      sessionManager: device.sessions,
      incomingMessages: server.inboxes[device.id]!.stream,
      directory: () => devices.directory,
      apiClient: FakeDeviceApi(server),
      acknowledge: hub.acknowledgeMessage,
      media: media,
    )..start();
    sender = OwnDeviceSender(
      database: device.db,
      signalRClient: hub,
      sessionManager: device.sessions,
      apiClient: FakeDeviceApi(server),
      directory: () => devices.directory,
    );
    sync = ContactSyncService(
      database: device.db,
      sender: sender,
      directory: () => devices.directory,
      controls: inbox.ownControls,
      linkEvents: devices.ownLinkEvents,
    )..start();
    transfer = HistoryTransferService(
      database: device.db,
      sender: sender,
      directory: () => devices.directory,
      controls: inbox.ownControls,
      media: media,
    )..start();
    contacts = ContactsController(
      database: device.db,
      onLocalChange: sync.contactChanged,
      remoteChanges: inbox.contactsChanged,
    );
  }

  static Future<_Node> create(
    TestDevice device,
    FakeMultiDeviceServer server,
    _Relay relay,
  ) async =>
      _Node._(device, server, await server.deviceServiceFor(device), relay);

  final TestDevice device;
  final FakeMultiDeviceServer server;
  final DeviceService devices;
  final FakeHubClient hub;
  final MediaService media;
  late final MessageInboxService inbox;
  late final OwnDeviceSender sender;
  late final ContactSyncService sync;
  late final HistoryTransferService transfer;
  late final ContactsController contacts;

  String get id => device.id;
  AppDatabase get db => device.db;

  Future<Contact?> contact(String id) => (db.select(
    db.contacts,
  )..where((c) => c.deviceId.equals(id))).getSingleOrNull();

  Future<String?> nameOf(String id) async => (await contact(id))?.displayName;

  Future<Conversation?> conversation(String id) => (db.select(
    db.conversations,
  )..where((c) => c.id.equals(id))).getSingleOrNull();

  Future<List<Message>> messages() => db.select(db.messages).get();

  Future<void> close() async {
    contacts.dispose();
    transfer.dispose();
    await sync.dispose();
    await inbox.dispose();
  }
}

void main() {
  late FakeMultiDeviceServer server;
  late _Relay relay;
  late _Node phone;
  late _Node web;
  late _Node web2;
  late _Node bob;
  var listVersion = 0;

  Future<DeviceListEntry> entryFor(_Node companion) async => DeviceListEntry(
    deviceId: companion.id,
    identityKey: await companion.device.keys.getPublicIdentityKey(),
    signingKey: (await companion.device.keys
        .getSignedIdentityBundle())['signingKey']!,
    consentSig: await signDeviceLinkConsent(
      companionSigningKey: await companion.device.keys.getSigningKeyPair(),
      primaryDeviceId: phoneId,
      companionDeviceId: companion.id,
    ),
  );

  /// What Settings > Linked devices does: the companion consented, the
  /// phone signs the list with it. Waits until the companion knows.
  Future<void> link(_Node companion) async {
    companion.devices.expectLink(phoneId);
    server.recordConsent(companion.id, phoneId);
    await phone.devices.addCompanion(await entryFor(companion));
    listVersion++;
    await until(() => companion.devices.isCompanion);
  }

  Future<void> insertMessage(
    _Node node,
    String id,
    String conversationId, {
    String? sender,
    String body = 'hello',
  }) => node.db
      .into(node.db.messages)
      .insert(
        MessagesCompanion.insert(
          id: id,
          conversationId: conversationId,
          senderId: sender ?? conversationId,
          body: Value(body),
          createdAt: DateTime.utc(2026, 11, 1, 8),
        ),
        mode: InsertMode.insertOrIgnore,
      );

  /// The phone's state before any device is linked.
  Future<void> seedPhone() async {
    final db = phone.db;
    await db
        .into(db.contacts)
        .insert(
          ContactsCompanion.insert(
            deviceId: bobId,
            userHandle: 'CT-BOB0-0001',
            displayName: const Value('Bob'),
            identityKey: Uint8List(0),
            addedAt: DateTime.utc(2026, 10, 1),
            nameChangedAt: const Value(1000),
          ),
        );
    await db
        .into(db.contacts)
        .insert(
          ContactsCompanion.insert(
            deviceId: carolId,
            userHandle: 'CT-CAR0-0001',
            identityKey: Uint8List(0),
            addedAt: DateTime.utc(2026, 10, 2),
            isBot: const Value(true),
          ),
        );
    for (final c in [
      ConversationsCompanion.insert(id: bobId, type: 'direct'),
      ConversationsCompanion.insert(
        id: 'g1',
        type: 'group',
        title: const Value('Team'),
      ),
      ConversationsCompanion.insert(
        id: 'biz',
        type: 'group',
        title: const Value('Acme desk'),
        organizationId: const Value('org-1'),
        organizationName: const Value('Acme'),
      ),
    ]) {
      await db.into(db.conversations).insert(c);
    }
    await insertMessage(phone, 'm1', bobId);
    await insertMessage(phone, 'm2', bobId, sender: phoneId, body: 'hi Bob');
    await insertMessage(phone, 'm3', 'g1', sender: bobId, body: 'team news');
    await insertMessage(phone, 'm4', 'biz', sender: bobId, body: 'invoice');
  }

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    server = FakeMultiDeviceServer();
    relay = _Relay();
    listVersion = 0;
    final devices = [
      for (final id in [phoneId, webId, web2Id, bobId])
        await TestDevice.create(id),
    ];
    devices.forEach(server.add);
    phone = await _Node.create(devices[0], server, relay);
    web = await _Node.create(devices[1], server, relay);
    web2 = await _Node.create(devices[2], server, relay);
    bob = await _Node.create(devices[3], server, relay);
    await seedPhone();
  });

  tearDown(() async {
    for (final node in [phone, web, web2, bob]) {
      await node.close();
    }
    await server.close();
    for (final node in [phone, web, web2, bob]) {
      await node.device.close();
    }
  });

  group('contact sync', () {
    test(
      'after linking, the web shows the phone\'s contacts and chat titles',
      () async {
        await link(web);

        await until(() async => await web.nameOf(bobId) == 'Bob');
        final bobRow = (await web.contact(bobId))!;
        expect(bobRow.userHandle, 'CT-BOB0-0001');
        expect(bobRow.nameChangedAt, 1000);
        // Never synced: each device verifies the safety number itself.
        expect(bobRow.verified, isFalse);
        final carol = (await web.contact(carolId))!;
        expect(carol.displayName, isNull);
        expect(carol.isBot, isTrue);
        await until(
          () async => (await web.conversation('g1'))?.title == 'Team',
        );
        final biz = (await web.conversation('biz'))!;
        expect(biz.organizationId, 'org-1');
        expect(biz.organizationName, 'Acme');
        expect((await web.conversation(bobId))!.type, 'direct');
        // Headers only: no message travels with a snapshot.
        expect(await web.messages(), isEmpty);
        expect(listVersion, 1);
      },
    );

    test('a rename on the web reaches the phone and the second web', () async {
      await link(web);
      await link(web2);
      await until(() async => await web2.nameOf(bobId) == 'Bob');

      await web.contacts.renameContact(bobId, '  Bobby  ');

      for (final node in [phone, web2]) {
        await until(() async => await node.nameOf(bobId) == 'Bobby');
      }
      expect(
        web.contacts.contacts
            .firstWhere((c) => c.deviceId == bobId)
            .displayName,
        'Bobby',
      );
      // The phone's contact list reloads on its own (chat titles use it).
      await phone.contacts.loadContacts();
      await until(
        () => phone.contacts.contacts.any((c) => c.displayName == 'Bobby'),
      );

      // Clearing the name syncs too.
      await web2.contacts.renameContact(bobId, '');
      for (final node in [phone, web]) {
        await until(() async => await node.nameOf(bobId) == null);
      }
    });

    test('concurrent renames end with the same name everywhere', () async {
      await link(web);
      await link(web2);
      await until(() async => await web2.nameOf(bobId) == 'Bob');

      await Future.wait([
        phone.contacts.renameContact(bobId, 'Phone name'),
        web.contacts.renameContact(bobId, 'Web name'),
        web2.contacts.renameContact(bobId, 'Web2 name'),
      ]);

      Future<Set<String?>> names() async => {
        for (final node in [phone, web, web2]) await node.nameOf(bobId),
      };
      await until(() async => (await names()).length == 1);
      final rows = [
        for (final n in [phone, web, web2]) (await n.contact(bobId))!,
      ];
      expect(rows.map((r) => r.nameChangedAt).toSet(), hasLength(1));
      expect([
        'Phone name',
        'Web name',
        'Web2 name',
      ], contains(rows.first.displayName));
    });

    test('an older snapshot cannot undo a newer rename', () async {
      await link(web);
      await until(() async => await web.nameOf(bobId) == 'Bob');
      await web.contacts.renameContact(bobId, 'New');
      await until(() async => await phone.nameOf(bobId) == 'New');

      // A stale snapshot (name written at 1000) arrives later.
      await phone.sender.send(
        contactSyncType,
        ContactSyncPayload.snapshot([
          SyncedContact(
            deviceId: bobId,
            userHandle: 'CT-BOB0-0001',
            displayName: 'Old',
            isBot: false,
            addedAt: DateTime.utc(2026, 10, 1),
            nameChangedAt: 1000,
          ),
        ], const []).encode(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await MessageProcessingQueue.forDatabase(web.db).run(() async {});
      expect(await web.nameOf(bobId), 'New');
    });

    test(
      'a contact-sync from a device that is not ours is acked and dropped',
      () async {
        await link(web);
        await until(() async => await web.nameOf(bobId) == 'Bob');
        // Bob (a contact, another identity) forges a sync for A's phone.
        await bob.device.sessions.initiateSession(
          phoneId,
          await phone.device.keyBundle(),
        );
        const messageId = 'f0000000-0000-4000-8000-000000000001';
        final payload = jsonEncode({
          'v': 1,
          'id': messageId,
          'type': contactSyncType,
          'body': ContactSyncPayload.upsert([
            SyncedContact(
              deviceId: bobId,
              userHandle: 'CT-BOB0-0001',
              displayName: 'Hacked',
              isBot: false,
              addedAt: DateTime.utc(2026, 10, 1),
              nameChangedAt: 1 << 50,
            ),
          ]).encode(),
          'groupId': null,
          'to': phoneId,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
        });
        final envelope = await bob.device.sessions.encryptMessage(
          phoneId,
          payload,
        );
        server.inboxes[phoneId]!.add({
          'senderId': bobId,
          'messageId': messageId,
          'encryptedBody': base64Encode(utf8.encode(envelope)),
          'groupId': null,
        });

        await until(() => phone.hub.acks.contains(messageId));
        expect(await phone.nameOf(bobId), 'Bob');
        expect(
          await (phone.db.select(
            phone.db.messages,
          )..where((m) => m.id.equals(messageId))).get(),
          isEmpty,
        );
        // Not counted as an own device that understands syncs.
        expect(
          await (phone.db.select(
            phone.db.backupState,
          )..where((s) => s.key.equals('$ownSyncSeenPrefix$bobId'))).get(),
          isEmpty,
        );
      },
    );

    test('a primary without companions sends nothing', () async {
      expect(await phone.sync.sendSnapshot(), isFalse);
      expect(await phone.sync.contactChanged(bobId), isFalse);
      expect(
        await (phone.db.select(
          phone.db.backupState,
        )..where((s) => s.key.like('$ownSyncOutboxPrefix%'))).get(),
        isEmpty,
      );
    });

    test('a device that never answered is reported as silent', () async {
      await link(web);
      await until(() async => await web.nameOf(bobId) == 'Bob');
      // The web asked for a snapshot when it was linked: it is known.
      await until(() async => (await phone.sync.silentDevices()).isEmpty);
      // A device that never sent anything (as an old app would not).
      await (phone.db.delete(
        phone.db.backupState,
      )..where((s) => s.key.like('$ownSyncSeenPrefix%'))).go();
      expect(await phone.sync.silentDevices(), [webId]);
    });
  });

  group('history transfer', () {
    Future<void> linkWithContacts(_Node node) async {
      await link(node);
      await until(() async => await node.nameOf(bobId) == 'Bob');
    }

    test('happy path: the web receives the phone\'s messages', () async {
      await linkWithContacts(web);
      final code = await web.transfer.startReceiving();
      expect(web.transfer.phase, HistoryTransferPhase.showingCode);
      expect(HistoryTransferCode.parse(code)!.targetDeviceId, webId);

      expect(await phone.transfer.prepare(code), isNull);
      expect(phone.transfer.phase, HistoryTransferPhase.confirm);
      // bob + g1; the business chat is left out for a companion.
      expect(phone.transfer.chatCount, 2);
      expect(phone.transfer.archiveBytes, greaterThan(0));
      await phone.transfer.confirm();

      await until(() => web.transfer.phase == HistoryTransferPhase.done);
      await until(() => phone.transfer.phase == HistoryTransferPhase.done);
      final received = {for (final m in await web.messages()) m.id: m};
      expect(received.keys.toSet(), {'m1', 'm2', 'm3'});
      expect(received['m2']!.body, 'hi Bob');
      expect(web.transfer.importedMessages, 3);
      // Business is primary-only in v1: header yes, messages no.
      expect((await web.conversation('biz'))!.organizationId, 'org-1');
      // The source deleted the relay copy on "done"; no temp file is left.
      expect(relay.blobs, isEmpty);
      expect(relay.deleted, hasLength(1));
      expect(
        await web.media.store.exists(relay.deleted.single, historyArchiveName),
        isFalse,
      );
    });

    test(
      'the transfer from a companion to the primary includes business chats',
      () async {
        await linkWithContacts(web);
        await phone.db.delete(phone.db.messages).go();
        await insertMessage(web, 'w1', 'biz', sender: bobId, body: 'kept');
        await insertMessage(web, 'w2', bobId, body: 'from web');
        final code = await phone.transfer.startReceiving();
        expect(await web.transfer.prepare(code), isNull);
        await web.transfer.confirm();
        await until(() => phone.transfer.phase == HistoryTransferPhase.done);
        expect({for (final m in await phone.messages()) m.id}, {'w1', 'w2'});
      },
    );

    test('into a non-empty device it merges without duplicates', () async {
      await linkWithContacts(web);
      await insertMessage(web, 'm1', bobId);
      await insertMessage(
        web,
        'own',
        bobId,
        sender: phoneId,
        body: 'only here',
      );
      await web.contacts.renameContact(bobId, 'Newer on web');
      await until(() async => await phone.nameOf(bobId) == 'Newer on web');
      // The phone's archive carries the same (synced) name; a stale one
      // would lose against the newer rename anyway.
      final code = await web.transfer.startReceiving();
      await phone.transfer.prepare(code);
      await phone.transfer.confirm();
      await until(() => web.transfer.phase == HistoryTransferPhase.done);

      final ids = [for (final m in await web.messages()) m.id]..sort();
      expect(ids, ['m1', 'm2', 'm3', 'own']);
      expect(await web.nameOf(bobId), 'Newer on web');
      expect((await web.conversation(bobId))!.unreadCount, 0);
    });

    test('a code of a device that is not ours is refused', () async {
      await linkWithContacts(web);
      final pair = await newHistoryTransferKeyPair();
      final code = HistoryTransferCode(
        targetDeviceId: bobId,
        transferId: newHistoryTransferId(),
        targetPublicKey: await historyTransferPublicKey(pair),
      ).encode();
      expect(
        await phone.transfer.prepare(code),
        HistoryTransferError.notOwnDevice,
      );
      expect(
        await phone.transfer.prepare('calltype://contact/CT-BOB0-0001'),
        HistoryTransferError.invalidCode,
      );
      // This device itself is not a target either.
      final self = HistoryTransferCode(
        targetDeviceId: phoneId,
        transferId: newHistoryTransferId(),
        targetPublicKey: await historyTransferPublicKey(pair),
      ).encode();
      expect(
        await phone.transfer.prepare(self),
        HistoryTransferError.notOwnDevice,
      );
      expect(relay.created, isEmpty);
    });

    test('a key wrapped for another ephemeral key is refused', () async {
      await linkWithContacts(web);
      final shown = HistoryTransferCode.parse(
        await web.transfer.startReceiving(),
      )!;
      // Same device and transfer id, but somebody else's key (a forged code).
      final forged = HistoryTransferCode(
        targetDeviceId: shown.targetDeviceId,
        transferId: shown.transferId,
        targetPublicKey: await historyTransferPublicKey(
          await newHistoryTransferKeyPair(),
        ),
      );
      await phone.transfer.prepare(forged.encode());
      await phone.transfer.confirm();

      await until(() => web.transfer.phase == HistoryTransferPhase.failed);
      expect(web.transfer.error, HistoryTransferError.wrongKey);
      expect(await web.messages(), isEmpty);
      await phone.transfer.cancel();
      expect(relay.blobs, isEmpty);
    });

    test('a tampered archive is refused and nothing is imported', () async {
      await linkWithContacts(web);
      relay.tamper = true;
      final code = await web.transfer.startReceiving();
      await phone.transfer.prepare(code);
      await phone.transfer.confirm();

      await until(() => web.transfer.phase == HistoryTransferPhase.failed);
      expect(web.transfer.error, HistoryTransferError.damaged);
      expect(await web.messages(), isEmpty);
    });

    test('cancel cleans up on both sides', () async {
      await linkWithContacts(web);
      final code = await web.transfer.startReceiving();
      // The target gives up: its key is gone and a late offer is ignored.
      await web.transfer.cancel();
      expect(web.transfer.code, isNull);
      expect(web.transfer.phase, HistoryTransferPhase.idle);

      await phone.transfer.prepare(code);
      await phone.transfer.confirm();
      expect(phone.transfer.phase, HistoryTransferPhase.waitingForTarget);
      expect(relay.blobs, hasLength(1));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(web.transfer.phase, HistoryTransferPhase.idle);
      expect(await web.messages(), isEmpty);

      // The source gives up: the upload is withdrawn from the relay.
      await phone.transfer.cancel();
      expect(relay.blobs, isEmpty);
      expect(phone.transfer.phase, HistoryTransferPhase.idle);
    });
  });
}
