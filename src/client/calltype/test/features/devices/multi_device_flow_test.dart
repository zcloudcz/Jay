import 'package:calltype/core/storage/database.dart';
import 'package:calltype/features/chat/chat_controller.dart';
import 'package:calltype/features/chat/message_inbox_service.dart';
import 'package:calltype_core/devices/device_directory.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_multi_device_server.dart';
import '../../helpers/test_device.dart';

const aPhoneId = 'a0000000-0000-4000-8000-000000000001';
const aWebId = 'a0000000-0000-4000-8000-000000000002';
const bobId = 'b0000000-0000-4000-8000-000000000001';

/// One app instance: real database, real ratchets, the real inbox and chat
/// controller. Only the network is the in-memory fake server.
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
    apiClient: FakeDeviceApi(server),
    conversationId: conversationId,
    directory: directory,
  );

  Future<List<Message>> messages() => device.db.select(device.db.messages).get();

  Future<Conversation?> conversation(String id) => (device.db.select(
    device.db.conversations,
  )..where((c) => c.id.equals(id))).getSingleOrNull();

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

  /// Lets every delivered envelope reach its inbox and be processed.
  Future<void> settle() async {
    for (var round = 0; round < 3; round++) {
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
    aPhone = _Node(devices[0], server);
    aWeb = _Node(devices[1], server);
    bob = _Node(devices[2], server);
    // A links its web device (what Settings > Linked devices does) and both
    // of A's devices verify the list.
    await server.link(aPhone.device, [aWeb.device], version: 1);
    await aPhone.directory.refresh(aPhoneId, ensurePinned: (_) async {});
    await aWeb.directory.refresh(aPhoneId, ensurePinned: server.pinFor(aWeb.device));
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

  test('a message to A reaches both of A\'s devices, in the chat with B', () async {
    final toA = bob.chat(aPhoneId);
    addTearDown(toA.dispose);

    await toA.sendMessage('hello both');
    await settle();

    expect((await bob.messages()).single.status, 'sent');
    for (final node in [aPhone, aWeb]) {
      final message = (await node.messages()).single;
      expect(message.body, 'hello both');
      expect(message.conversationId, bobId);
      expect(message.senderId, bobId);
      expect(message.status, 'delivered');
      expect((await node.conversation(bobId))!.unreadCount, 1);
    }
    // B learned A's list from the stale answer and keeps it.
    expect(await bob.directory.devicesOf(aPhoneId), [aPhoneId, aWebId]);
  });

  test('the web device replies and retracts; B and A\'s phone follow', () async {
    final toA = bob.chat(aPhoneId);
    addTearDown(toA.dispose);
    await toA.sendMessage('hello both');
    await settle();

    final fromWeb = aWeb.chat(bobId);
    addTearDown(fromWeb.dispose);
    expect(fromWeb.myIdentityId, aPhoneId);
    await fromWeb.sendMessage('from the web');
    await settle();

    final atBob = (await bob.messages()).firstWhere((m) => m.body == 'from the web');
    expect(atBob.conversationId, aPhoneId);
    expect(atBob.senderId, aPhoneId);
    final copy = (await aPhone.messages()).firstWhere((m) => m.body == 'from the web');
    expect(copy.conversationId, bobId);
    expect(copy.senderId, aPhoneId);
    expect(copy.status, 'sent');
    // Only B's message is unread on the phone; its own copy is not.
    expect((await aPhone.conversation(bobId))!.unreadCount, 1);

    final sent = (await aWeb.messages()).firstWhere((m) => m.body == 'from the web');
    expect(await fromWeb.deleteForEveryone(sent.id), isTrue);
    await settle();
    for (final node in [bob, aPhone]) {
      expect(
        (await node.messages()).firstWhere((m) => m.id == sent.id).deleted,
        isTrue,
      );
    }
  });

  test('after A removes the web device, B\'s next message leaves it out', () async {
    final toA = bob.chat(aPhoneId);
    addTearDown(toA.dispose);
    await toA.sendMessage('hello both');
    await settle();
    await server.link(aPhone.device, [], version: 2);
    final webBefore = (await aWeb.messages()).length;

    await toA.sendMessage('phone only');
    await settle();

    expect((await bob.messages()).map((m) => m.status), everyElement('sent'));
    expect((await aPhone.messages()).map((m) => m.body), contains('phone only'));
    expect(await aWeb.messages(), hasLength(webBefore));
    expect(await bob.directory.devicesOf(aPhoneId), [aPhoneId]);
  });
}
