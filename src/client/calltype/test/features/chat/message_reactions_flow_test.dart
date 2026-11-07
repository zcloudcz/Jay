import 'dart:convert';

import 'package:calltype/core/storage/database.dart';
import 'package:calltype/features/chat/chat_controller.dart';
import 'package:calltype/features/chat/message_inbox_service.dart';
import 'package:calltype/features/chat/reactions.dart';
import 'package:calltype_core/devices/device_directory.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_multi_device_server.dart';
import '../../helpers/test_device.dart';

/// Reactions end to end (spec 2026-11-07-message-reactions): real databases,
/// ratchets, inboxes and chat controllers; only the hub is the in-memory
/// fake server. A has a phone (primary) and a linked web device; B is a
/// contact.
const aPhoneId = 'a0000000-0000-4000-8000-000000000001';
const aWebId = 'a0000000-0000-4000-8000-000000000002';
const bobId = 'b0000000-0000-4000-8000-000000000001';

/// `GET /groups/{id}` answers "not business" (or business when [business]),
/// which delete, edit and react ask before touching a group.
class _Api extends FakeDeviceApi {
  _Api(super.server);
  static bool business = false;

  @override
  Dio get transport {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) => handler.resolve(
          Response(
            requestOptions: options,
            data: business
                ? <String, dynamic>{
                    'organizationId': 'org',
                    'organizationName': 'Acme',
                    'auditorDeviceId': 'aud',
                  }
                : <String, dynamic>{},
          ),
        ),
      ),
    );
    return dio;
  }
}

class _Node {
  _Node(this.device, this.server) : hub = FakeHubClient(server, device.id) {
    directory = server.directoryFor(device);
    inbox = MessageInboxService(
      database: device.db,
      sessionManager: device.sessions,
      incomingMessages: server.inboxes[device.id]!.stream,
      directory: () => directory,
      apiClient: _Api(server),
      acknowledge: hub.acknowledgeMessage,
    )..start();
    inbox.appliedReactions.listen(applied.add);
  }

  final TestDevice device;
  final FakeMultiDeviceServer server;
  final FakeHubClient hub;
  late final DeviceDirectory directory;
  late final MessageInboxService inbox;
  final applied = <AppliedReaction>[];

  ChatController chat(String conversationId) => ChatController(
    database: device.db,
    signalRClient: hub,
    sessionManager: device.sessions,
    inbox: inbox,
    apiClient: _Api(server),
    conversationId: conversationId,
    directory: directory,
  );

  Future<List<Message>> messages() =>
      device.db.select(device.db.messages).get();

  Future<List<MessageReaction>> reactions() =>
      device.db.select(device.db.messageReactions).get();

  Future<Conversation> conversation(String id) => (device.db.select(
    device.db.conversations,
  )..where((c) => c.id.equals(id))).getSingle();

  Future<void> settle() =>
      MessageProcessingQueue.forDatabase(device.db).run(() async {});

  Future<void> close() async {
    await inbox.dispose();
    hub.dispose();
  }
}

void main() {
  late FakeMultiDeviceServer server;
  late _Node aPhone;
  late _Node aWeb;
  late _Node bob;

  Future<void> settle() async {
    for (var round = 0; round < 3; round++) {
      await Future<void>.delayed(Duration.zero);
      for (final node in [aPhone, aWeb, bob]) {
        await node.settle();
      }
    }
  }

  /// Lets the controllers' drift watchers deliver.
  Future<void> watchers() => Future<void>.delayed(Duration.zero);

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    _Api.business = false;
    server = FakeMultiDeviceServer();
    final devices = [
      for (final id in [aPhoneId, aWebId, bobId]) await TestDevice.create(id),
    ];
    devices.forEach(server.add);
    aPhone = _Node(devices[0], server);
    aWeb = _Node(devices[1], server);
    bob = _Node(devices[2], server);
    await server.link(aPhone.device, [aWeb.device], version: 1);
    await aPhone.directory.refresh(aPhoneId, ensurePinned: (_) async {});
    await aWeb.directory.refresh(
      aPhoneId,
      ensurePinned: server.pinFor(aWeb.device),
    );
    await bob.device.db
        .into(bob.device.db.conversations)
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

  /// B writes to A; returns the message id (the same on every device).
  Future<String> bobSays(String text) async {
    final toA = bob.chat(aPhoneId);
    addTearDown(toA.dispose);
    await toA.sendMessage(text);
    await settle();
    return (await bob.messages()).firstWhere((m) => m.body == text).id;
  }

  test('a reaction reaches the peer and the reactor\'s other device, '
      'without a row, unread count or reorder', () async {
    final id = await bobSays('ship it?');
    final phoneBefore = await aPhone.conversation(bobId);
    final bobBefore = await bob.conversation(aPhoneId);

    final chat = aPhone.chat(bobId);
    addTearDown(chat.dispose);
    expect(await chat.react(id, '👍'), isTrue);
    await settle();

    for (final node in [aPhone, aWeb, bob]) {
      final row = (await node.reactions()).single;
      expect(row.messageId, id);
      expect(row.reactorId, aPhoneId, reason: 'identity, not device');
      expect(row.emoji, '👍');
      // No control row survives anywhere.
      expect((await node.messages()).map((m) => m.id), [id]);
    }
    expect(
      (await aWeb.reactions()).single.conversationId,
      bobId,
      reason: 'the own copy lands in the chat named by `to`',
    );
    final bobAfter = await bob.conversation(aPhoneId);
    expect(bobAfter.unreadCount, bobBefore.unreadCount);
    expect(bobAfter.lastMessageAt, bobBefore.lastMessageAt);
    final phoneAfter = await aPhone.conversation(bobId);
    expect(phoneAfter.lastMessageAt, phoneBefore.lastMessageAt);
    // Bob was reacted to by somebody else: the notification feed has it.
    expect(bob.applied.single.target?.id, id);
    expect(bob.applied.single.emoji, '👍');

    await watchers();
    expect(chat.reactionsOf(id), [
      const ReactionSummary(emoji: '👍', reactorIds: [aPhoneId], mine: true),
    ]);
    expect(chat.myReactionOf(id), '👍');
  });

  test(
    'another emoji replaces, the same emoji again removes, everywhere',
    () async {
      final id = await bobSays('lunch?');
      final fromWeb = aWeb.chat(bobId);
      addTearDown(fromWeb.dispose);

      expect(await fromWeb.react(id, '👍'), isTrue);
      await settle();
      expect(await fromWeb.react(id, '❤️'), isTrue);
      await settle();
      for (final node in [aPhone, aWeb, bob]) {
        expect((await node.reactions()).single.emoji, '❤️');
      }

      expect(await fromWeb.react(id, '❤️'), isTrue);
      await settle();
      for (final node in [aPhone, aWeb, bob]) {
        // A removal is a tombstone row, so a late older reaction cannot win.
        expect((await node.reactions()).single.emoji, '');
      }
      final atBob = bob.chat(aPhoneId);
      addTearDown(atBob.dispose);
      await watchers();
      expect(atBob.reactionsOf(id), isEmpty);
    },
  );

  test('group: every member\'s reaction counts once per person', () async {
    server.groups['g'] = [bobId, aPhoneId];
    await bob.device.db
        .into(bob.device.db.conversations)
        .insert(ConversationsCompanion.insert(id: 'g', type: 'group'));
    final atBob = bob.chat('g');
    addTearDown(atBob.dispose);
    await atBob.sendMessage('release today');
    await settle();
    final id = (await bob.messages())
        .firstWhere((m) => m.conversationId == 'g')
        .id;

    final fromWeb = aWeb.chat('g');
    addTearDown(fromWeb.dispose);
    expect(await fromWeb.react(id, '🎉'), isTrue);
    expect(await atBob.react(id, '🎉'), isTrue);
    await settle();

    // The phone has no chat open: Bob's message is its one unread, the two
    // reactions add nothing.
    expect((await aPhone.conversation('g')).unreadCount, 1);
    final atPhone = aPhone.chat('g');
    addTearDown(atPhone.dispose);
    await watchers();
    for (final controller in [atBob, fromWeb, atPhone]) {
      final chips = controller.reactionsOf(id);
      expect(chips.single.emoji, '🎉');
      expect(chips.single.reactorIds.toSet(), {aPhoneId, bobId});
      expect(chips.single.mine, isTrue);
    }
    for (final node in [aPhone, aWeb, bob]) {
      expect((await node.reactions()).map((r) => r.conversationId).toSet(), {
        'g',
      });
    }
  });

  test('group: refused when the server says business (fail closed)', () async {
    server.groups['g'] = [bobId, aPhoneId];
    await bob.device.db
        .into(bob.device.db.conversations)
        .insert(ConversationsCompanion.insert(id: 'g', type: 'group'));
    final atBob = bob.chat('g');
    addTearDown(atBob.dispose);
    await atBob.sendMessage('contract');
    await settle();
    final id = (await bob.messages()).single.id;
    _Api.business = true;
    expect(await atBob.react(id, '👍'), isFalse);
    expect(await bob.reactions(), isEmpty);
  });

  test(
    'delete for everyone removes the message\'s reactions on every device',
    () async {
      final id = await bobSays('typo');
      final chat = aPhone.chat(bobId);
      addTearDown(chat.dispose);
      await chat.react(id, '😂');
      await settle();
      expect(await bob.reactions(), hasLength(1));

      final atBob = bob.chat(aPhoneId);
      addTearDown(atBob.dispose);
      expect(await atBob.deleteForEveryone(id), isTrue);
      await settle();
      for (final node in [aPhone, aWeb, bob]) {
        expect(await node.reactions(), isEmpty);
        expect((await node.messages()).single.deleted, isTrue);
      }
      // And a tombstone takes no new reactions.
      expect(await chat.react(id, '😂'), isFalse);
    },
  );

  test('delete for me removes the reactions of that message locally', () async {
    final id = await bobSays('hi');
    final chat = aPhone.chat(bobId);
    addTearDown(chat.dispose);
    await chat.react(id, '👍');
    await settle();
    await chat.deleteForMe(id);
    expect(await aPhone.reactions(), isEmpty);
    expect(await bob.reactions(), hasLength(1), reason: 'only on this device');
  });

  test('a failed send restores the previous reaction', () async {
    final id = await bobSays('vote');
    final chat = aPhone.chat(bobId);
    addTearDown(chat.dispose);
    await chat.react(id, '👍');
    await settle();

    final offline = _OfflineHub(server, aPhoneId);
    addTearDown(offline.dispose);
    final failing = ChatController(
      database: aPhone.device.db,
      signalRClient: offline,
      sessionManager: aPhone.device.sessions,
      inbox: aPhone.inbox,
      apiClient: _Api(server),
      conversationId: bobId,
      directory: aPhone.directory,
    );
    addTearDown(failing.dispose);
    expect(await failing.react(id, '😢'), isFalse);
    expect((await aPhone.reactions()).single.emoji, '👍');
    expect(await failing.react(id, '👍'), isFalse); // a removal fails too
    expect((await aPhone.reactions()).single.emoji, '👍');
    // Nothing is left in the outbox or as a control row.
    expect((await aPhone.messages()).map((m) => m.id), [id]);
    expect(
      await (aPhone.device.db.select(
        aPhone.device.db.backupState,
      )..where((s) => s.key.like('outbox:%') | s.key.like('extra:%'))).get(),
      isEmpty,
    );
  });

  test('a first reaction that fails leaves no reaction', () async {
    final id = await bobSays('vote');
    final offline = _OfflineHub(server, aPhoneId);
    addTearDown(offline.dispose);
    final failing = ChatController(
      database: aPhone.device.db,
      signalRClient: offline,
      sessionManager: aPhone.device.sessions,
      inbox: aPhone.inbox,
      apiClient: _Api(server),
      conversationId: bobId,
      directory: aPhone.directory,
    );
    addTearDown(failing.dispose);
    expect(await failing.react(id, '👍'), isFalse);
    expect(await aPhone.reactions(), isEmpty);
  });

  test(
    'canReact: not on pending, failed, deleted, call log or business',
    () async {
      final chat = aPhone.chat(bobId);
      addTearDown(chat.dispose);
      Message m({
        String type = 'text',
        String status = 'delivered',
        bool deleted = false,
      }) => Message(
        id: 'x',
        conversationId: bobId,
        senderId: bobId,
        body: 'b',
        type: type,
        status: status,
        createdAt: DateTime(2026),
        forwarded: false,
        deleted: deleted,
      );
      expect(chat.canReact(m(), business: false), isTrue);
      expect(chat.canReact(m(type: 'file'), business: false), isTrue);
      expect(chat.canReact(m(type: 'media'), business: false), isTrue);
      expect(chat.canReact(m(), business: true), isFalse);
      expect(chat.canReact(m(status: 'sending'), business: false), isFalse);
      expect(chat.canReact(m(status: 'failed'), business: false), isFalse);
      expect(chat.canReact(m(deleted: true), business: false), isFalse);
      expect(chat.canReact(m(type: 'call-event'), business: false), isFalse);
      expect(chat.canReact(m(type: 'device-change'), business: false), isFalse);
      expect(await chat.react('missing', '👍'), isFalse);
      final id = await bobSays('x');
      expect(await chat.react(id, 'not an emoji'), isFalse);
    },
  );

  test(
    'the wire payload: type reaction, JSON body, millisecond createdAt',
    () async {
      final id = await bobSays('payload?');
      final spy = _SpyHub(server, aPhoneId);
      addTearDown(spy.dispose);
      final chat = ChatController(
        database: aPhone.device.db,
        signalRClient: spy,
        sessionManager: aPhone.device.sessions,
        inbox: aPhone.inbox,
        apiClient: _Api(server),
        conversationId: bobId,
        directory: aPhone.directory,
      );
      addTearDown(chat.dispose);
      await chat.react(id, '🙏');
      final envelope = spy.payloads.single[bobId]!;
      final payload =
          jsonDecode(
                await bob.device.sessions.decryptMessage(
                  aPhoneId,
                  utf8.decode(base64Decode(envelope)),
                ),
              )
              as Map<String, dynamic>;
      expect(payload['type'], 'reaction');
      expect(payload['to'], bobId);
      expect(jsonDecode(payload['body'] as String), {
        'targetId': id,
        'emoji': '🙏',
      });
      final createdAt = DateTime.parse(payload['createdAt'] as String);
      expect(
        createdAt.millisecondsSinceEpoch,
        (await aPhone.reactions()).single.reactedAt,
      );
    },
  );
}

/// Every send fails like a lost connection.
class _OfflineHub extends FakeHubClient {
  _OfflineHub(super.server, super.deviceId);

  @override
  Future<void> sendDirectFanout(
    String recipientIdentityId,
    Map<String, String> encryptedPayloads, {
    required String messageId,
  }) async => throw StateError('offline');
}

/// Records the envelopes instead of delivering them.
class _SpyHub extends FakeHubClient {
  _SpyHub(super.server, super.deviceId);
  final payloads = <Map<String, String>>[];

  @override
  Future<void> sendDirectFanout(
    String recipientIdentityId,
    Map<String, String> encryptedPayloads, {
    required String messageId,
  }) async => payloads.add(Map.of(encryptedPayloads));
}
