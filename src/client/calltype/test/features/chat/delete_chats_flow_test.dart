import 'dart:convert';

import 'package:calltype/features/chat/chat_controller.dart';
import 'package:calltype/features/chat/chat_deletion.dart';
import 'package:calltype/features/chat/message_inbox_service.dart';
import 'package:calltype/features/contacts/contact_sync.dart';
import 'package:calltype/features/contacts/contacts_controller.dart';
import 'package:calltype/features/devices/own_device_sender.dart';
import 'package:calltype/features/media/media_service.dart';
import 'package:calltype/features/media/media_store_memory.dart';
import 'package:calltype/features/notifications/notification_content.dart';
import 'package:calltype_core/devices/device_directory.dart';
import 'package:calltype_core/messaging/chat_deleted.dart';
import 'package:calltype_core/messaging/contact_sync.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_multi_device_server.dart';
import '../../helpers/test_device.dart';
import '../media/media_fakes.dart';
import '../notifications/fake_notifications.dart';

/// Delete chats and contacts, leave groups, end to end (spec
/// 2026-11-09-delete-chats-contacts): real databases, ratchets, inboxes and
/// notification services; only the hub is the in-memory fake server. A has
/// a phone (primary) and a linked web device; B is a contact.
const aPhoneId = 'a0000000-0000-4000-8000-000000000001';
const aWebId = 'a0000000-0000-4000-8000-000000000002';
const bobId = 'b0000000-0000-4000-8000-000000000001';
const otherId = 'c0000000-0000-4000-8000-000000000003';
const groupId = 'd0000000-0000-4000-8000-000000000004';

/// Records which media folders a deletion removed.
class _RecordingMedia extends MediaService {
  _RecordingMedia()
    : super(remote: FakeMediaRemote(), store: MemoryMediaStore(), web: false);
  final deleted = <String>[];
  @override
  Future<void> deleteLocal(String folder) async => deleted.add(folder);
}

/// `GET /groups/{id}/members` and `DELETE .../members/{id}` as the server
/// answers them (GroupEndpoints.RemoveMember after this spec).
class _GroupApi extends FakeDeviceApi {
  _GroupApi(super.server);
  List<GroupMemberInfo> members = [];
  int? listStatus;
  int? removeStatus;
  Object? removeData;
  final removed = <String>[];

  DioException _error(String path, int status, [Object? data]) => DioException(
    requestOptions: RequestOptions(path: path),
    response: Response(
      requestOptions: RequestOptions(path: path),
      statusCode: status,
      data: data,
    ),
  );

  @override
  Future<List<GroupMemberInfo>> getGroupMemberInfos(String groupId) async {
    final status = listStatus;
    if (status != null) throw _error('/groups/$groupId/members', status);
    return members;
  }

  @override
  Future<void> removeGroupMember(String groupId, String deviceId) async {
    final status = removeStatus;
    if (status != null) {
      throw _error('/groups/$groupId/members/$deviceId', status, removeData);
    }
    removed.add(deviceId);
  }
}

class _Node {
  _Node(this.device, this.server) : hub = FakeHubClient(server, device.id) {
    directory = server.directoryFor(device);
    api = _GroupApi(server);
    inbox = MessageInboxService(
      database: device.db,
      sessionManager: device.sessions,
      incomingMessages: server.inboxes[device.id]!.stream,
      directory: () => directory,
      apiClient: api,
      acknowledge: hub.acknowledgeMessage,
      media: media,
    )..start();
    sender = OwnDeviceSender(
      database: device.db,
      signalRClient: hub,
      sessionManager: device.sessions,
      apiClient: api,
      directory: () => directory,
    );
    deletion = ChatDeletionService(
      database: device.db,
      sender: sender,
      directory: () => directory,
      apiClient: api,
      media: media,
      onDeleted: notifications.service.onConversationRead,
    );
    contactSync = ContactSyncService(
      database: device.db,
      sender: sender,
      directory: () => directory,
      controls: inbox.ownControls,
    )..start();
    contacts = ContactsController(
      database: device.db,
      onLocalRemove: contactSync.contactRemoved,
      remoteChanges: inbox.contactsChanged,
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
  final media = _RecordingMedia();
  late final DeviceDirectory directory;
  late final _GroupApi api;
  late final MessageInboxService inbox;
  late final OwnDeviceSender sender;
  late final ChatDeletionService deletion;
  late final ContactSyncService contactSync;
  late final ContactsController contacts;

  ChatController chat(String conversationId) => ChatController(
    database: device.db,
    signalRClient: hub,
    sessionManager: device.sessions,
    inbox: inbox,
    apiClient: api,
    conversationId: conversationId,
    directory: directory,
  );

  AppDatabase get db => device.db;

  Future<Conversation?> conversation(String id) => (db.select(
    db.conversations,
  )..where((c) => c.id.equals(id))).getSingleOrNull();

  Future<List<Message>> messagesOf(String id) =>
      (db.select(db.messages)..where((m) => m.conversationId.equals(id))).get();

  Future<String?> state(String key) async => (await (db.select(
    db.backupState,
  )..where((s) => s.key.equals(key))).getSingleOrNull())?.value;

  Future<void> settle() =>
      MessageProcessingQueue.forDatabase(db).run(() async {});

  Future<void> close() async {
    contacts.dispose();
    await contactSync.dispose();
    await inbox.dispose();
    notifications.service.dispose();
    hub.dispose();
  }
}

/// Seeds [conversationId] with one message [messageId] and everything that
/// hangs on it: a reaction, a pin, a poll vote and per-message state.
Future<void> _seed(
  AppDatabase db,
  String conversationId,
  String messageId, {
  String type = 'direct',
  String body = 'seeded',
  String messageType = 'text',
  DateTime? createdAt,
}) async {
  await db
      .into(db.conversations)
      .insert(
        ConversationsCompanion.insert(id: conversationId, type: type),
        mode: InsertMode.insertOrIgnore,
      );
  await db
      .into(db.messages)
      .insert(
        MessagesCompanion.insert(
          id: messageId,
          conversationId: conversationId,
          senderId: conversationId,
          body: Value(body),
          type: Value(messageType),
          status: const Value('delivered'),
          createdAt: createdAt ?? DateTime.now(),
        ),
      );
  await db
      .into(db.messageReactions)
      .insert(
        MessageReactionsCompanion.insert(
          messageId: messageId,
          reactorId: conversationId,
          conversationId: conversationId,
          emoji: '👍',
          reactedAt: 1,
        ),
      );
  await db
      .into(db.messagePins)
      .insert(
        MessagePinsCompanion.insert(
          conversationId: conversationId,
          messageId: messageId,
          pinned: true,
          pinnedBy: conversationId,
          changedAt: 1,
        ),
      );
  await db
      .into(db.pollVotes)
      .insert(
        PollVotesCompanion.insert(
          pollId: messageId,
          voterId: conversationId,
          conversationId: conversationId,
          options: '[0]',
          votedAt: 1,
        ),
      );
  for (final key in ['outbox:$messageId', 'extra:$messageId']) {
    await db
        .into(db.backupState)
        .insert(BackupStateCompanion.insert(key: key, value: '{}'));
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

  test('deleting on the phone removes the chat and everything on it there '
      'and on the web; other chats and Bob\'s copy stay', () async {
    await bobSays('hi');
    for (final node in [aPhone, aWeb]) {
      await _seed(node.db, bobId, 'seeded-bob');
      await _seed(node.db, otherId, 'seeded-other');
      for (final key in ['draft:$bobId', 'read-upto:$bobId']) {
        await node.db
            .into(node.db.backupState)
            .insert(BackupStateCompanion.insert(key: key, value: '1'));
      }
    }
    final webRows = (await aWeb.db.select(aWeb.db.messages).get()).length;

    expect(await aPhone.deletion.deleteChat(bobId), isTrue);
    await settle();

    for (final node in [aPhone, aWeb]) {
      expect(await node.conversation(bobId), isNull);
      expect(await node.messagesOf(bobId), isEmpty);
      for (final key in [
        'draft:$bobId',
        'read-upto:$bobId',
        'outbox:seeded-bob',
        'extra:seeded-bob',
      ]) {
        expect(await node.state(key), isNull, reason: key);
      }
      final reactions = await node.db.select(node.db.messageReactions).get();
      final pins = await node.db.select(node.db.messagePins).get();
      final votes = await node.db.select(node.db.pollVotes).get();
      for (final rows in [
        reactions.map((r) => r.conversationId),
        pins.map((p) => p.conversationId),
        votes.map((v) => v.conversationId),
      ]) {
        expect(rows, [otherId]);
      }
      // The other chat is untouched.
      expect(await node.conversation(otherId), isNotNull);
      expect(await node.messagesOf(otherId), hasLength(1));
      expect(await node.state('outbox:seeded-other'), isNotNull);
      expect(await node.state('$chatDeletedPrefix$bobId'), isNotNull);
    }
    // A control message: the web got no row for it.
    expect(
      (await aWeb.db.select(aWeb.db.messages).get()).length,
      webRows - 2,
      reason: 'only the two messages of the deleted chat went',
    );
    expect(cancelled(aWeb), bobChat);
    expect(cancelled(aPhone), bobChat);
    // Bob keeps his copy.
    expect(await bob.conversation(aPhoneId), isNotNull);
    expect(await bob.messagesOf(aPhoneId), hasLength(1));
  });

  test('a new message after the deletion recreates the chat', () async {
    await bobSays('one');
    await aPhone.deletion.deleteChat(bobId);
    await settle();
    expect(await aWeb.conversation(bobId), isNull);

    await bobSays('two');
    for (final node in [aPhone, aWeb]) {
      final rows = await node.messagesOf(bobId);
      expect(rows.map((m) => m.body), ['two']);
      expect((await node.conversation(bobId))!.unreadCount, 1);
    }
  });

  test('a chat-deleted keeps messages created after deletedAt and caps the '
      'unread count', () async {
    await bobSays('one');
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await bobSays('two');
    final rows = await (aWeb.db.select(
      aWeb.db.messages,
    )..orderBy([(m) => OrderingTerm.asc(m.createdAt)])).get();
    expect((await aWeb.conversation(bobId))!.unreadCount, 2);

    await aPhone.sender.send(
      chatDeletedType,
      ChatDeletedPayload(
        conversationId: bobId,
        deletedAt: rows.first.createdAt.millisecondsSinceEpoch,
      ).encode(),
    );
    await settle();

    expect((await aWeb.messagesOf(bobId)).map((m) => m.body), ['two']);
    expect((await aWeb.conversation(bobId))!.unreadCount, 1);
    // The phone was not touched by its own message.
    expect(await aPhone.messagesOf(bobId), hasLength(2));
  });

  test(
    'a chat-deleted for an unknown chat is acked and changes nothing',
    () async {
      final acks = aWeb.hub.acks.length;
      await aPhone.sender.send(
        chatDeletedType,
        const ChatDeletedPayload(
          conversationId: otherId,
          deletedAt: 5,
        ).encode(),
      );
      await settle();
      expect(aWeb.hub.acks.length, acks + 1);
      expect(await aWeb.state('$chatDeletedPrefix$otherId'), isNull);
      expect(cancelled(aWeb), isEmpty);
    },
  );

  test('a chat-deleted from somebody else is acked and ignored', () async {
    await bobSays('hi');
    const id = 'forged-delete';
    final envelope = await bob.device.sessions.encryptMessage(
      aWebId,
      jsonEncode({
        'v': 1,
        'id': id,
        'groupId': null,
        'type': chatDeletedType,
        'body': ChatDeletedPayload(
          conversationId: bobId,
          deletedAt: DateTime.now().millisecondsSinceEpoch + 60000,
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
    expect(await aWeb.messagesOf(bobId), hasLength(1));
    expect(await aWeb.conversation(bobId), isNotNull);
  });

  test('without other own devices nothing is sent', () async {
    final toBob = aPhone.chat(bobId);
    addTearDown(toBob.dispose);
    await toBob.sendMessage('x');
    await settle();
    expect(await bob.deletion.deleteChat(aPhoneId), isFalse);
    expect(await bob.conversation(aPhoneId), isNull);
    expect(await bob.messagesOf(aPhoneId), isEmpty);
  });

  test('media files of the deleted chat go unless another chat still '
      'references them', () async {
    final (only, _) = await encryptForTest(
      Uint8List(8),
      id: '11111111-0000-4000-8000-000000000001',
    );
    final (shared, _) = await encryptForTest(
      Uint8List(8),
      id: '11111111-0000-4000-8000-000000000002',
    );
    await _seed(
      aPhone.db,
      bobId,
      'media-only',
      messageType: 'media',
      body: only.encode(),
    );
    await _seed(
      aPhone.db,
      bobId,
      'media-shared',
      messageType: 'media',
      body: shared.encode(),
    );
    await _seed(
      aPhone.db,
      otherId,
      'media-forwarded',
      messageType: 'media',
      body: shared.encode(),
    );

    await aPhone.deletion.deleteChat(bobId);

    expect(aPhone.media.deleted, [only.id]);
    expect(await aPhone.messagesOf(otherId), hasLength(1));
  });

  test('a snapshot does not bring a deleted chat back', () async {
    await bobSays('hi');
    await aPhone.deletion.deleteChat(bobId);
    await settle();
    final changed = await applySyncedConversations(aWeb.db, [
      const SyncedConversation(id: bobId, type: 'direct'),
      const SyncedConversation(id: otherId, type: 'direct'),
    ]);
    expect(changed, isTrue);
    expect(await aWeb.conversation(bobId), isNull);
    expect(await aWeb.conversation(otherId), isNotNull);
  });

  test('deleting a contact writes the tombstone and removes it on the web, '
      'the chat stays unless deleted too', () async {
    await bobSays('hi');
    for (final node in [aPhone, aWeb]) {
      await node.db
          .into(node.db.contacts)
          .insert(
            ContactsCompanion.insert(
              deviceId: bobId,
              userHandle: 'CT-BOB0-0001',
              identityKey: Uint8List(0),
              addedAt: DateTime.now().subtract(const Duration(days: 1)),
            ),
          );
    }

    await aPhone.contacts.deleteContact(bobId);
    await settle();

    for (final node in [aPhone, aWeb]) {
      expect(await node.db.select(node.db.contacts).get(), isEmpty);
      expect(await node.state('$contactRemovedPrefix$bobId'), isNotNull);
      expect(await node.conversation(bobId), isNotNull);
    }
    expect(aPhone.contacts.contacts, isEmpty);
    // Not blocked: Bob still gets through.
    await bobSays('still here');
    expect(await aWeb.messagesOf(bobId), hasLength(2));
  });

  group('leave group', () {
    Future<void> seedGroup() async {
      for (final node in [aPhone, aWeb]) {
        await _seed(node.db, groupId, 'group-msg', type: 'group');
      }
    }

    test('the web leaves for its identity by removing the phone, then the '
        'chat goes on both devices', () async {
      await seedGroup();
      aWeb.api.members = const [
        GroupMemberInfo(deviceId: bobId, role: 'admin'),
        GroupMemberInfo(deviceId: aPhoneId),
      ];

      expect(await aWeb.deletion.leaveGroup(groupId), LeaveGroupResult.left);
      await settle();

      expect(aWeb.api.removed, [aPhoneId]);
      expect(await aWeb.conversation(groupId), isNull);
      expect(await aPhone.conversation(groupId), isNull);
    });

    test('the last admin is told so and nothing is deleted', () async {
      await seedGroup();
      aPhone.api
        ..members = const [
          GroupMemberInfo(deviceId: aPhoneId, role: 'admin'),
          GroupMemberInfo(deviceId: bobId),
        ]
        ..removeStatus = 409
        ..removeData = {
          'error': 'The last administrator cannot be removed.',
          'code': 'last_admin',
        };

      expect(
        await aPhone.deletion.leaveGroup(groupId),
        LeaveGroupResult.lastAdmin,
      );
      await settle();
      expect(await aPhone.conversation(groupId), isNotNull);
      expect(await aWeb.conversation(groupId), isNotNull);
    });

    test(
      'a group this identity is no member of any more is just deleted',
      () async {
        await seedGroup();
        aPhone.api.listStatus = 403;
        expect(
          await aPhone.deletion.leaveGroup(groupId),
          LeaveGroupResult.left,
        );
        await settle();
        expect(await aPhone.conversation(groupId), isNull);
        expect(await aWeb.conversation(groupId), isNull);
      },
    );

    test('a server error keeps the chat', () async {
      await seedGroup();
      aPhone.api
        ..members = const [GroupMemberInfo(deviceId: aPhoneId)]
        ..removeStatus = 500;
      expect(
        await aPhone.deletion.leaveGroup(groupId),
        LeaveGroupResult.failed,
      );
      aPhone.api
        ..removeStatus = null
        ..listStatus = 503;
      expect(
        await aPhone.deletion.leaveGroup(groupId),
        LeaveGroupResult.failed,
      );
      expect(await aPhone.conversation(groupId), isNotNull);
      expect(aPhone.api.removed, isEmpty);
    });

    test('deleting a group chat does not leave the group', () async {
      await seedGroup();
      await aPhone.deletion.deleteChat(groupId);
      await settle();
      expect(aPhone.api.removed, isEmpty);
      expect(await aWeb.conversation(groupId), isNull);
    });
  });
}
