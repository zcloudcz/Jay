import 'package:calltype/features/chat/chat_controller.dart';
import 'package:calltype/features/chat/message_inbox_service.dart';
import 'package:calltype/features/chat/message_sender.dart';
import 'package:calltype/features/groups/group_topic_service.dart';
import 'package:calltype/features/groups/group_topic_store.dart';
import 'package:calltype_core/devices/device_directory.dart';
import 'package:calltype_core/network/group_dtos.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_multi_device_server.dart';
import '../../helpers/test_device.dart';

/// Group topics end to end (spec 2026-11-13-group-topics rows 5, 6, 10, 14):
/// real databases, ratchets, inboxes and the real send path; only the hub
/// and the group endpoints are faked. A has a phone (admin) and a linked
/// web device; B is a member who does not know the group yet.
const aPhoneId = 'a0000000-0000-4000-8000-000000000001';
const aWebId = 'a0000000-0000-4000-8000-000000000002';
const bobId = 'b0000000-0000-4000-8000-000000000001';
const groupId = 'c0000000-0000-4000-8000-000000000001';

/// The server's topic record (S2/S3), shared by every device's API.
class _TopicServer {
  GroupTopicRecord? record;
  var nextVersion = 1000;

  /// Who `PUT /topic` refuses, with which status (403 non-admin, 404 old).
  int? refuseWith;
}

class _Api extends FakeDeviceApi {
  _Api(super.server, this.topics, this.caller);
  final _TopicServer topics;
  final String caller;

  @override
  Future<GroupTopicRecord> recordGroupTopic(String groupId) async {
    final status = topics.refuseWith;
    if (status != null) {
      final options = RequestOptions(path: '/groups/$groupId/topic');
      throw DioException(
        requestOptions: options,
        response: Response(requestOptions: options, statusCode: status),
        type: DioExceptionType.badResponse,
      );
    }
    return topics.record = GroupTopicRecord(
      version: topics.nextVersion++,
      updatedBy: caller,
    );
  }

  @override
  Future<GroupDetails> getGroup(String groupId) async =>
      GroupDetails(groupId: groupId, topic: topics.record);
}

class _Node {
  _Node(this.device, this.server, this.topics)
    : hub = FakeHubClient(server, device.id) {
    directory = server.directoryFor(device);
    inbox = MessageInboxService(
      database: device.db,
      sessionManager: device.sessions,
      incomingMessages: server.inboxes[device.id]!.stream,
      directory: () => directory,
      apiClient: _Api(server, topics, device.id),
      acknowledge: hub.acknowledgeMessage,
    )..start();
  }

  final TestDevice device;
  final FakeMultiDeviceServer server;
  final _TopicServer topics;
  final FakeHubClient hub;
  late final DeviceDirectory directory;
  late final MessageInboxService inbox;

  GroupTopicService service() {
    final api = _Api(server, topics, device.id);
    return GroupTopicService(
      database: device.db,
      apiClient: api,
      sender: () => MessageSender(
        database: device.db,
        signalRClient: hub,
        sessionManager: device.sessions,
        apiClient: api,
        directory: directory,
      ),
      directory: () => directory,
    );
  }

  ChatController chat() => ChatController(
    database: device.db,
    signalRClient: hub,
    sessionManager: device.sessions,
    inbox: inbox,
    apiClient: _Api(server, topics, device.id),
    conversationId: groupId,
    directory: directory,
  );

  Future<StoredGroupTopic?> topic() => readGroupTopic(device.db, groupId);

  Future<List<Message>> messages() =>
      device.db.select(device.db.messages).get();

  Future<Conversation?> conversation() => (device.db.select(
    device.db.conversations,
  )..where((c) => c.id.equals(groupId))).getSingleOrNull();

  Future<void> settle() =>
      MessageProcessingQueue.forDatabase(device.db).run(() async {});

  Future<void> close() async {
    await inbox.dispose();
    hub.dispose();
  }
}

void main() {
  late FakeMultiDeviceServer server;
  late _TopicServer topics;
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

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    server = FakeMultiDeviceServer();
    topics = _TopicServer();
    final devices = [
      for (final id in [aPhoneId, aWebId, bobId]) await TestDevice.create(id),
    ];
    devices.forEach(server.add);
    aPhone = _Node(devices[0], server, topics);
    aWeb = _Node(devices[1], server, topics);
    bob = _Node(devices[2], server, topics);
    await server.link(aPhone.device, [aWeb.device], version: 1);
    await aPhone.directory.refresh(aPhoneId, ensurePinned: (_) async {});
    await aWeb.directory.refresh(
      aPhoneId,
      ensurePinned: server.pinFor(aWeb.device),
    );
    server.groups[groupId] = [aPhoneId, bobId];
    // Only the creator knows the group so far (as right after POST /groups).
    await aPhone.device.db
        .into(aPhone.device.db.conversations)
        .insert(
          ConversationsCompanion.insert(
            id: groupId,
            type: 'group',
            title: const Value('Brno trip'),
          ),
        );
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

  test('a topic reaches the members and the own other device, opens the '
      'unknown group without unread and leaves no row anywhere', () async {
    final result = await aPhone.service().setTopic(groupId, ' Plan it. ');
    expect(result.ok, isTrue);
    expect(result.sent, GroupTopicSent.sent);
    await settle();

    for (final node in [aPhone, aWeb, bob]) {
      final topic = await node.topic();
      expect(topic?.topic, 'Plan it.');
      expect(topic?.version, 1000);
      expect(topic?.setBy, aPhoneId, reason: 'identity, not device');
      expect(await node.messages(), isEmpty, reason: 'no control row left');
      final conversation = await node.conversation();
      expect(conversation?.type, 'group');
      expect(conversation?.title, 'Brno trip');
      expect(conversation?.unreadCount, 0);
    }
  });

  test('an open chat follows the stored topic (header line)', () async {
    final open = bob.chat();
    addTearDown(open.dispose);
    await aPhone.service().setTopic(groupId, 'Live');
    await settle();
    await Future<void>.delayed(Duration.zero);
    expect(open.groupTopic, 'Live');
    // The hidden control row never shows as a bubble on the sender.
    final mine = aPhone.chat();
    addTearDown(mine.dispose);
    await Future<void>.delayed(Duration.zero);
    expect(mine.messages, isEmpty);
    expect(mine.groupTopic, 'Live');
  });

  test('a newer topic replaces the older one everywhere', () async {
    await aPhone.service().setTopic(groupId, 'first');
    await settle();
    await aPhone.service().setTopic(groupId, '');
    await settle();
    for (final node in [aPhone, aWeb, bob]) {
      final topic = await node.topic();
      expect(topic?.topic, '');
      expect(topic?.version, 1001);
    }
  });

  test('a refused PUT sends nothing and stores nothing', () async {
    for (final (status, error) in [
      (403, GroupTopicError.notAdmin),
      (404, GroupTopicError.unsupported),
      (500, GroupTopicError.failed),
    ]) {
      topics.refuseWith = status;
      final result = await aPhone.service().setTopic(groupId, 'nope');
      expect(result.error, error);
    }
    await settle();
    for (final node in [aPhone, aWeb, bob]) {
      expect(await node.topic(), isNull);
      expect(await node.messages(), isEmpty);
    }
    expect(await bob.conversation(), isNull);
  });

  test('a business group is refused before the PUT', () async {
    await (aPhone.device.db.update(aPhone.device.db.conversations)
          ..where((c) => c.id.equals(groupId)))
        .write(const ConversationsCompanion(organizationId: Value('org')));
    final result = await aPhone.service().setTopic(groupId, 'x');
    expect(result.error, GroupTopicError.business);
    expect(topics.record, isNull);
  });

  test('more than 4000 characters is refused before the PUT', () async {
    final result = await aPhone.service().setTopic(groupId, 'x' * 4001);
    expect(result.error, GroupTopicError.tooLong);
    expect(topics.record, isNull);
  });
}
