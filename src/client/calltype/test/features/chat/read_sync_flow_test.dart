import 'dart:convert';

import 'package:calltype/features/chat/chat_controller.dart';
import 'package:calltype/features/chat/message_inbox_service.dart';
import 'package:calltype/features/chat/read_sync.dart';
import 'package:calltype/features/devices/own_device_sender.dart';
import 'package:calltype/features/notifications/notification_content.dart';
import 'package:calltype_core/devices/device_directory.dart';
import 'package:calltype_core/messaging/read_state.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_multi_device_server.dart';
import '../../helpers/test_device.dart';
import '../notifications/fake_notifications.dart';

/// Read state between own devices end to end (spec
/// 2026-11-09-auto-resend-read-sync, part 2): real databases, ratchets,
/// inboxes, chat controllers and notification services on fakes; only the
/// hub is the in-memory fake server. A has a phone (primary) and a linked
/// web device; B is a contact.
const aPhoneId = 'a0000000-0000-4000-8000-000000000001';
const aWebId = 'a0000000-0000-4000-8000-000000000002';
const bobId = 'b0000000-0000-4000-8000-000000000001';

class _Node {
  _Node(this.device, this.server) : hub = FakeHubClient(server, device.id) {
    directory = server.directoryFor(device);
    inbox = MessageInboxService(
      database: device.db,
      sessionManager: device.sessions,
      incomingMessages: server.inboxes[device.id]!.stream,
      directory: () => directory,
      apiClient: FakeDeviceApi(server),
      acknowledge: hub.acknowledgeMessage,
    )..start();
    sender = OwnDeviceSender(
      database: device.db,
      signalRClient: hub,
      sessionManager: device.sessions,
      apiClient: FakeDeviceApi(server),
      directory: () => directory,
    );
    readSync = ReadStateService(
      database: device.db,
      sender: sender,
      directory: () => directory,
      foreground: () => foreground,
      openConversation: () => open,
      minInterval: const Duration(milliseconds: 200),
    );
    notifications.focused = false;
    notifications.directory.selfIdentityId = server.primaryOf(device.id);
    inbox.persistedMessages.listen(notifications.service.onMessage);
    inbox.readElsewhere.listen(notifications.service.onConversationRead);
  }

  final TestDevice device;
  final FakeMultiDeviceServer server;
  final FakeHubClient hub;
  final notifications = NotificationHarness();
  late final DeviceDirectory directory;
  late final MessageInboxService inbox;
  late final OwnDeviceSender sender;
  late final ReadStateService readSync;
  bool foreground = true;
  String? open;

  ChatController chat(String conversationId) => ChatController(
    database: device.db,
    signalRClient: hub,
    sessionManager: device.sessions,
    inbox: inbox,
    apiClient: FakeDeviceApi(server),
    conversationId: conversationId,
    directory: directory,
    readSync: readSync,
  );

  AppDatabase get db => device.db;

  Future<Conversation?> conversation(String id) => (db.select(
    db.conversations,
  )..where((c) => c.id.equals(id))).getSingleOrNull();

  Future<int> unread(String id) async =>
      (await conversation(id))?.unreadCount ?? -1;

  Future<void> settle() =>
      MessageProcessingQueue.forDatabase(db).run(() async {});

  Future<void> close() async {
    readSync.dispose();
    await inbox.dispose();
    notifications.service.dispose();
    hub.dispose();
  }
}

void main() {
  late FakeMultiDeviceServer server;
  late _Node aPhone;
  late _Node aWeb;
  late _Node bob;

  Future<void> settle() async {
    for (var round = 0; round < 4; round++) {
      await Future<void>.delayed(Duration.zero);
      for (final node in [aPhone, aWeb, bob]) {
        await node.settle();
      }
    }
  }

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    server = FakeMultiDeviceServer();
    final devices = [
      for (final id in [aPhoneId, aWebId, bobId]) await TestDevice.create(id),
    ];
    devices.forEach(server.add);
    await server.link(devices[0], [devices[1]], version: 1);
    aPhone = _Node(devices[0], server);
    aWeb = _Node(devices[1], server);
    bob = _Node(devices[2], server);
    for (final node in [aPhone, aWeb, bob]) {
      await node.notifications.service.start();
    }
    await aPhone.directory.refresh(aPhoneId, ensurePinned: (_) async {});
    await aWeb.directory.refresh(
      aPhoneId,
      ensurePinned: server.pinFor(aWeb.device),
    );
    await bob.db
        .into(bob.db.conversations)
        .insert(ConversationsCompanion.insert(id: aPhoneId, type: 'direct'));
  });

  tearDown(() async {
    for (final node in [aPhone, aWeb, bob]) {
      await node.close();
    }
    await server.close();
    for (final node in [aPhone, aWeb, bob]) {
      await node.device.close();
    }
  });

  /// B writes to A (reaches A's phone and web).
  Future<void> bobSays(String text) async {
    final toA = bob.chat(aPhoneId);
    addTearDown(toA.dispose);
    await toA.sendMessage(text);
    await settle();
  }

  const bobChat = [
    (NotificationKind.message, bobId),
    (NotificationKind.groupMessage, bobId),
  ];

  List<(NotificationKind, String)> cancelled(_Node node) => [
    for (final t in node.notifications.notifier.cancelled)
      (t.kind, t.conversationId),
  ];

  test('reading on the phone clears unread and the notification on the web, '
      'without a message row', () async {
    await bobSays('lunch?');
    expect(await aPhone.unread(bobId), 1);
    expect(await aWeb.unread(bobId), 1);
    expect(aWeb.notifications.notifier.shown, hasLength(1));
    final webRows = await aWeb.db.select(aWeb.db.messages).get();

    final chat = aPhone.chat(bobId);
    addTearDown(chat.dispose);
    await settle();

    expect(await aPhone.unread(bobId), 0);
    expect(await aWeb.unread(bobId), 0);
    expect(cancelled(aWeb), bobChat);
    expect(
      await aWeb.db.select(aWeb.db.messages).get(),
      webRows,
      reason: 'a control message, no row',
    );
    expect(
      await readUpToOf(aWeb.db, bobId),
      await readUpToOf(aPhone.db, bobId),
    );
    // Nothing went back to the phone or to Bob.
    expect(cancelled(aPhone), isEmpty);
    expect(await bob.unread(aPhoneId), 0);
  });

  test(
    'a newer message after the read stays unread on the other device',
    () async {
      await bobSays('one');
      final chat = aPhone.chat(bobId);
      await settle();
      chat.dispose();
      expect(await aWeb.unread(bobId), 0);

      await bobSays('two');
      expect(await aWeb.unread(bobId), 1);
      expect(aWeb.notifications.notifier.shown, hasLength(2));
    },
  );

  test('a chat open in a background app does not send a read state', () async {
    await bobSays('psst');
    aPhone.foreground = false;
    final chat = aPhone.chat(bobId);
    addTearDown(chat.dispose);
    await settle();
    expect(await aPhone.unread(bobId), 0, reason: 'local behaviour unchanged');
    expect(await aWeb.unread(bobId), 1);

    // Back in the foreground with that chat on screen.
    aPhone
      ..foreground = true
      ..open = bobId;
    await aPhone.readSync.onResume();
    await settle();
    expect(await aWeb.unread(bobId), 0);
  });

  test('reads in quick succession send at most one state per interval, the '
      'newest at the end', () async {
    final readSync = ReadStateService(
      database: aPhone.db,
      sender: aPhone.sender,
      directory: () => aPhone.directory,
      foreground: () => true,
      minInterval: const Duration(seconds: 3),
    );
    addTearDown(readSync.dispose);
    await bobSays('a');
    final chat = ChatController(
      database: aPhone.db,
      signalRClient: aPhone.hub,
      sessionManager: aPhone.device.sessions,
      inbox: aPhone.inbox,
      apiClient: FakeDeviceApi(server),
      conversationId: bobId,
      directory: aPhone.directory,
      readSync: readSync,
    );
    addTearDown(chat.dispose);
    await settle();
    expect(await aWeb.unread(bobId), 0);
    final first = await readUpToOf(aWeb.db, bobId);

    // Bob writes again within the interval (a later second, so the state
    // grows); the open chat marks it read at once.
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await bobSays('b');
    expect(await aPhone.unread(bobId), 0);
    expect(await aWeb.unread(bobId), 1, reason: 'the state waits');

    await Future<void>.delayed(const Duration(seconds: 2));
    await settle();
    expect(await aWeb.unread(bobId), 0);
    expect(await readUpToOf(aWeb.db, bobId), greaterThan(first!));
  });

  test('an older or equal read state is ignored, an unknown conversation is '
      'acked and dropped', () async {
    await bobSays('one');
    await Future<void>.delayed(const Duration(seconds: 1));
    await bobSays('two');
    final rows = await (aWeb.db.select(
      aWeb.db.messages,
    )..orderBy([(m) => OrderingTerm.asc(m.createdAt)])).get();
    final newest = rows.last.createdAt.millisecondsSinceEpoch;
    final oldest = rows.first.createdAt.millisecondsSinceEpoch;
    expect(await aWeb.unread(bobId), 2);

    // The newest state first, then an older one that arrives late.
    await aPhone.sender.send(
      readStateType,
      ReadStatePayload(conversationId: bobId, readUpTo: oldest).encode(),
    );
    await settle();
    expect(await aWeb.unread(bobId), 1, reason: '"two" is still unseen');
    expect(cancelled(aWeb), isEmpty);

    await aPhone.sender.send(
      readStateType,
      ReadStatePayload(conversationId: bobId, readUpTo: newest).encode(),
    );
    await settle();
    expect(await aWeb.unread(bobId), 0);

    final acks = aWeb.hub.acks.length;
    await aPhone.sender.send(
      readStateType,
      ReadStatePayload(conversationId: bobId, readUpTo: oldest).encode(),
    );
    await aPhone.sender.send(
      readStateType,
      const ReadStatePayload(
        conversationId: 'c0000000-0000-4000-8000-00000000000c',
        readUpTo: 5,
      ).encode(),
    );
    await settle();
    expect(aWeb.hub.acks.length, acks + 2, reason: 'both acked');
    expect(await readUpToOf(aWeb.db, bobId), newest);
    expect(
      await aWeb.conversation('c0000000-0000-4000-8000-00000000000c'),
      isNull,
    );
  });

  test('a read state never raises the unread count', () async {
    await bobSays('one');
    // Read locally while in the background: nothing stored or sent.
    aWeb.foreground = false;
    final local = aWeb.chat(bobId);
    await settle();
    local.dispose();
    expect(await aWeb.unread(bobId), 0);
    await aPhone.sender.send(
      readStateType,
      const ReadStatePayload(conversationId: bobId, readUpTo: 1000).encode(),
    );
    await settle();
    expect(await aWeb.unread(bobId), 0);
  });

  test('a read state from somebody else is acked and ignored', () async {
    await bobSays('hi');
    expect(await aWeb.unread(bobId), 1);
    // Bob already has a session with A's web (fan-out).
    const id = 'forged-read';
    final envelope = await bob.device.sessions.encryptMessage(
      aWebId,
      jsonEncode({
        'v': 1,
        'id': id,
        'groupId': null,
        'type': readStateType,
        'body': ReadStatePayload(
          conversationId: bobId,
          readUpTo: DateTime.now().millisecondsSinceEpoch,
        ).encode(),
        'createdAt': DateTime.now().toUtc().toIso8601String(),
      }),
    );
    server.inboxes[aWebId]!.add({
      'senderId': bobId,
      'messageId': id,
      'encryptedBody': base64Encode(utf8.encode(envelope)),
      'groupId': null,
    });
    await settle();
    expect(aWeb.hub.acks, contains(id));
    expect(await aWeb.unread(bobId), 1);
    expect(await readUpToOf(aWeb.db, bobId), isNull);
    expect(cancelled(aWeb), isEmpty);
  });

  test('without other own devices nothing is sent', () async {
    // Bob has no companions: opening a chat sends nothing.
    final toBob = aPhone.chat(bobId);
    addTearDown(toBob.dispose);
    await toBob.sendMessage('x');
    await settle();
    final chat = bob.chat(aPhoneId);
    addTearDown(chat.dispose);
    await settle();
    expect(await bob.readSync.conversationRead(aPhoneId), isFalse);
    expect(await readUpToOf(bob.db, aPhoneId), isNull);
  });
}
