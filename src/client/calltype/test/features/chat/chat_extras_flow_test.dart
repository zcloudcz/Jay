import 'package:calltype/core/storage/database.dart';
import 'package:calltype/features/chat/chat_controller.dart';
import 'package:calltype/features/chat/message_inbox_service.dart';
import 'package:calltype/features/chat/polls.dart';
import 'package:calltype_core/devices/device_directory.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_multi_device_server.dart';
import '../../helpers/test_device.dart';

/// Pins and polls end to end (spec 2026-11-08-chat-extras): real databases,
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
  }

  final TestDevice device;
  final FakeMultiDeviceServer server;
  final FakeHubClient hub;
  late final DeviceDirectory directory;
  late final MessageInboxService inbox;

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

  Future<List<MessagePin>> pins() =>
      device.db.select(device.db.messagePins).get();

  Future<List<PollVote>> votes() => device.db.select(device.db.pollVotes).get();

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

  final lunch = PollPayload.create(
    question: 'Lunch?',
    options: ['Pizza', 'Sushi', 'Salad'],
  );

  /// A sends [poll] to B from the phone; returns its id.
  Future<String> aPolls(PollPayload poll, {String conversation = bobId}) async {
    final chat = aPhone.chat(conversation);
    addTearDown(chat.dispose);
    expect(await chat.sendPoll(poll), isTrue);
    await settle();
    return (await aPhone.messages())
        .firstWhere((m) => m.type == pollMessageType)
        .id;
  }

  test('a poll reaches the peer and the own other device as a poll; votes '
      'and vote changes are live everywhere', () async {
    await bobSays('hi');
    final pollId = await aPolls(lunch);
    for (final node in [aPhone, aWeb, bob]) {
      final row = (await node.messages()).firstWhere((m) => m.id == pollId);
      expect(row.type, pollMessageType, reason: node.device.id);
      expect(PollPayload.tryDecode(row.body), lunch);
      expect(row.senderId, aPhoneId);
    }
    final before = await bob.conversation(aPhoneId);

    final atBob = bob.chat(aPhoneId);
    addTearDown(atBob.dispose);
    final atWeb = aWeb.chat(bobId);
    addTearDown(atWeb.dispose);
    expect(await atBob.vote(pollId, [1]), isTrue);
    expect(await atWeb.vote(pollId, [0]), isTrue);
    await settle();
    for (final node in [aPhone, aWeb, bob]) {
      expect(await node.votes(), hasLength(2), reason: node.device.id);
      // Votes are control messages: no row, no unread count.
      expect(
        (await node.messages()).where((m) => m.type == pollVoteType),
        isEmpty,
      );
    }
    final after = await bob.conversation(aPhoneId);
    expect(after.lastMessageAt, before.lastMessageAt);
    expect(after.unreadCount, before.unreadCount);

    final atPhone = aPhone.chat(bobId);
    addTearDown(atPhone.dispose);
    await watchers();
    final poll = atPhone.messages.firstWhere((m) => m.id == pollId);
    final results = atPhone.pollResultsOf(poll)!;
    expect(results.votersByOption, [
      [aPhoneId],
      [bobId],
      <String>[],
    ]);
    expect(results.mine, [0], reason: 'the web voted for the identity');
    expect(results.voterCount, 2);

    // Bob changes his mind, then withdraws.
    expect(await atBob.vote(pollId, [2]), isTrue);
    await settle();
    await watchers();
    expect(atPhone.pollResultsOf(poll)!.votersByOption[2], [bobId]);
    expect(await atBob.vote(pollId, []), isTrue);
    await settle();
    await watchers();
    expect(atPhone.pollResultsOf(poll)!.voterCount, 1);
  });

  test('a vote that does not fit the poll is refused before sending', () async {
    await bobSays('hi');
    final pollId = await aPolls(lunch);
    final atBob = bob.chat(aPhoneId);
    addTearDown(atBob.dispose);
    expect(await atBob.vote(pollId, [0, 1]), isFalse, reason: 'single choice');
    expect(await atBob.vote(pollId, [5]), isFalse);
    expect(await atBob.vote('missing', [0]), isFalse);
    await settle();
    expect(await aPhone.votes(), isEmpty);
    expect(await bob.votes(), isEmpty);
  });

  test('pin and unpin reach every device; any member may pin', () async {
    final id = await bobSays('meeting at 10');
    final atPhone = aPhone.chat(bobId);
    addTearDown(atPhone.dispose);
    expect(
      atPhone.canPin((await aPhone.messages()).single, business: false),
      isTrue,
    );
    expect(await atPhone.setPinned(id, true), isTrue);
    await settle();
    for (final node in [aPhone, aWeb, bob]) {
      final pin = (await node.pins()).single;
      expect(pin.messageId, id);
      expect(pin.pinned, isTrue);
      expect(pin.pinnedBy, aPhoneId, reason: 'identity, not device');
      expect((await node.messages()).map((m) => m.id), [id]);
    }
    final atBob = bob.chat(aPhoneId);
    addTearDown(atBob.dispose);
    await watchers();
    expect(atBob.pinnedMessages.map((m) => m.id), [id]);
    expect(atBob.isPinned(id), isTrue);

    // The other side unpins it.
    expect(await atBob.setPinned(id, false), isTrue);
    await settle();
    await watchers();
    for (final node in [aPhone, aWeb, bob]) {
      expect((await node.pins()).single.pinned, isFalse);
    }
    expect(atPhone.pinnedMessages, isEmpty);
  });

  test('a fourth pin unpins the oldest for everyone', () async {
    final ids = [for (var i = 0; i < 4; i++) await bobSays('note $i')];
    final atPhone = aPhone.chat(bobId);
    addTearDown(atPhone.dispose);
    await watchers();
    for (final id in ids.take(3)) {
      expect(await atPhone.setPinned(id, true), isTrue);
      // Distinct milliseconds: pins are ordered by their send time.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await watchers();
    }
    await settle();
    await watchers();
    expect(atPhone.pinReplacesOldest(ids[3]), isTrue);
    expect(await atPhone.setPinned(ids[3], true), isTrue);
    await settle();
    final atBob = bob.chat(aPhoneId);
    addTearDown(atBob.dispose);
    final atWeb = aWeb.chat(bobId);
    addTearDown(atWeb.dispose);
    await watchers();
    for (final controller in [atPhone, atBob, atWeb]) {
      expect(controller.pinnedMessages.map((m) => m.id), [
        ids[3],
        ids[2],
        ids[1],
      ]);
    }
    for (final node in [aPhone, aWeb, bob]) {
      final oldest = (await node.pins()).firstWhere(
        (p) => p.messageId == ids[0],
      );
      expect(oldest.pinned, isFalse, reason: 'an explicit unpin was sent');
    }
  });

  test(
    'group: polls and pins work; refused when the server says business',
    () async {
      server.groups['g'] = [bobId, aPhoneId];
      await bob.device.db
          .into(bob.device.db.conversations)
          .insert(ConversationsCompanion.insert(id: 'g', type: 'group'));
      final atBob = bob.chat('g');
      addTearDown(atBob.dispose);
      expect(await atBob.sendPoll(lunch), isTrue);
      await settle();
      final pollId = (await bob.messages()).single.id;
      for (final node in [aPhone, aWeb]) {
        final row = (await node.messages()).single;
        expect(row.type, pollMessageType);
        expect(row.conversationId, 'g');
      }
      final atWeb = aWeb.chat('g');
      addTearDown(atWeb.dispose);
      expect(await atWeb.vote(pollId, [2]), isTrue);
      expect(await atWeb.setPinned(pollId, true), isTrue);
      await settle();
      for (final node in [aPhone, aWeb, bob]) {
        expect((await node.votes()).single.voterId, aPhoneId);
        expect((await node.pins()).single.conversationId, 'g');
      }

      _Api.business = true;
      expect(await atBob.sendPoll(lunch), isFalse);
      expect(await atBob.vote(pollId, [0]), isFalse);
      expect(await atBob.setPinned(pollId, false), isFalse);
      await settle();
      expect(
        (await bob.messages()).where((m) => m.type == pollMessageType),
        hasLength(1),
      );
      expect((await bob.votes()).single.voterId, aPhoneId);
      expect((await bob.pins()).single.pinned, isTrue);
    },
  );

  test('delete for me drops the poll\'s votes and pins locally', () async {
    await bobSays('hi');
    final pollId = await aPolls(lunch);
    final atBob = bob.chat(aPhoneId);
    addTearDown(atBob.dispose);
    expect(await atBob.vote(pollId, [0]), isTrue);
    expect(await atBob.setPinned(pollId, true), isTrue);
    await settle();
    await atBob.deleteForMe(pollId);
    expect(await bob.votes(), isEmpty);
    expect(await bob.pins(), isEmpty);
    expect(await aPhone.votes(), hasLength(1), reason: 'only on this device');
  });

  test('reply to a poll quotes its question', () async {
    await bobSays('hi');
    final pollId = await aPolls(lunch);
    final poll = (await bob.messages()).firstWhere((m) => m.id == pollId);
    expect(ChatController.replyPreviewOf(poll), '📊 Lunch?');
  });
}
