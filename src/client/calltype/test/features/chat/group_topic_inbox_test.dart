import 'dart:async';
import 'dart:convert';

import 'package:calltype/features/chat/message_inbox_service.dart';
import 'package:calltype/features/groups/group_topic_store.dart';
import 'package:calltype_core/messaging/group_topic.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/network/group_dtos.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_device.dart';

/// `GET /groups/{id}` with a scripted topic record (or a thrown error).
class TopicRecordApi extends ApiClient {
  TopicRecordApi() : super(baseUrl: 'http://unused');

  GroupTopicRecord? record;
  Map<String, dynamic> raw = const {};
  Object? error;
  var calls = 0;

  @override
  Future<GroupDetails> getGroup(String groupId) async {
    calls++;
    final e = error;
    if (e != null) throw e;
    return GroupDetails(groupId: groupId, topic: record, raw: raw);
  }
}

/// The receiving side of `group-topic` (spec 2026-11-13-group-topics,
/// receiver rules 1-5 and row 10).
void main() {
  late TestDevice alice; // admin who sets the topic
  late TestDevice carol; // another member
  late TestDevice bob; // the receiver under test
  late StreamController<Map<String, dynamic>> transport;
  late MessageInboxService inbox;
  late TopicRecordApi api;
  late List<String> acks;
  late List<Object> errors;
  var nextId = 0;

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    alice = await TestDevice.create('alice');
    carol = await TestDevice.create('carol');
    bob = await TestDevice.create('bob');
    transport = StreamController<Map<String, dynamic>>();
    api = TopicRecordApi();
    acks = [];
    errors = [];
    inbox = MessageInboxService(
      database: bob.db,
      sessionManager: bob.sessions,
      directory: () => bob.directory,
      incomingMessages: transport.stream,
      apiClient: api,
      acknowledge: (sender, id) async => acks.add(id),
    );
    inbox.errors.listen(errors.add);
    inbox.start();
    await alice.sessions.initiateSession(bob.id, await bob.keyBundle());
    await carol.sessions.initiateSession(bob.id, await bob.keyBundle());
  });

  tearDown(() async {
    await inbox.dispose();
    await transport.close();
    await alice.close();
    await carol.close();
    await bob.close();
  });

  Future<String> deliver(
    TestDevice from,
    Map<String, dynamic> fields, {
    String? groupId = 'g',
    String? id,
    String? envelope,
  }) async {
    final messageId = id ?? 'm-${nextId++}';
    final encrypted =
        envelope ??
        await from.sessions.encryptMessage(
          bob.id,
          jsonEncode({'v': 1, 'id': messageId, 'groupId': groupId, ...fields}),
        );
    transport.add({
      'messageId': messageId,
      'senderId': from.id,
      'encryptedBody': base64Encode(utf8.encode(encrypted)),
      'groupId': groupId,
    });
    await Future<void>.delayed(Duration.zero);
    await MessageProcessingQueue.forDatabase(bob.db).run(() async {});
    return messageId;
  }

  Map<String, dynamic> topic(String text, int version) => {
    'type': groupTopicType,
    'body': GroupTopicPayload(topic: text, version: version).encode(),
    'groupName': 'Brno trip',
    'createdAt': '2026-11-13T10:15:30.123Z',
  };

  Future<void> group({String id = 'g', String? organizationId}) => bob.db
      .into(bob.db.conversations)
      .insert(
        ConversationsCompanion.insert(
          id: id,
          type: 'group',
          title: const Value('Brno trip'),
          organizationId: Value(organizationId),
        ),
      );

  void recorded(int version, {String by = 'alice'}) =>
      api.record = GroupTopicRecord(version: version, updatedBy: by);

  Future<StoredGroupTopic?> stored([String id = 'g']) =>
      readGroupTopic(bob.db, id);

  Future<int> messageRows() async =>
      (await bob.db.select(bob.db.messages).get()).length;

  test('a recorded topic from the recording admin is stored', () async {
    await group();
    recorded(5);
    final id = await deliver(alice, topic('  Plan the trip  ', 5));
    final t = await stored();
    expect(t?.topic, 'Plan the trip');
    expect(t?.version, 5);
    expect(t?.setBy, 'alice');
    expect(acks, [id]);
    expect(errors, isEmpty);
    // A control message: no row, no unread, no change of the chat order.
    expect(await messageRows(), 0);
    final c = await (bob.db.select(
      bob.db.conversations,
    )..where((c) => c.id.equals('g'))).getSingle();
    expect(c.unreadCount, 0);
    expect(c.lastMessageAt, isNull);
  });

  test('a version the server has not recorded is dropped and acked', () async {
    await group();
    recorded(6);
    final id = await deliver(alice, topic('stale or forged', 5));
    expect(await stored(), isNull);
    expect(acks, [id]);
  });

  test('another sender than the recording admin is dropped', () async {
    await group();
    recorded(5, by: 'alice');
    final id = await deliver(carol, topic('not mine to set', 5));
    expect(await stored(), isNull);
    expect(acks, [id]);
  });

  test('no record at all (never set, old server) is dropped', () async {
    await group();
    final id = await deliver(alice, topic('x', 5));
    expect(await stored(), isNull);
    expect(acks, [id]);
  });

  test('a 1:1 group-topic is dropped without asking the server', () async {
    recorded(5);
    final id = await deliver(alice, topic('x', 5), groupId: null);
    expect(await stored('alice'), isNull);
    expect(api.calls, 0);
    expect(acks, [id]);
  });

  test('a business group is dropped (local row or server record)', () async {
    await group(organizationId: 'org');
    recorded(5);
    final first = await deliver(alice, topic('x', 5));
    expect(await stored(), isNull);
    expect(api.calls, 0);
    // Unknown locally, but the server says it is an organization group.
    api.raw = {'organizationId': 'org'};
    final second = await deliver(alice, topic('x', 5), groupId: 'h');
    expect(await stored('h'), isNull);
    expect(
      await (bob.db.select(
        bob.db.conversations,
      )..where((c) => c.id.equals('h'))).getSingleOrNull(),
      isNull,
    );
    expect(acks, [first, second]);
  });

  test('a malformed body is dropped and acked', () async {
    await group();
    recorded(5);
    final id = await deliver(alice, {
      'type': groupTopicType,
      'body': '{"topic": 7, "version": 5}',
    });
    expect(await stored(), isNull);
    expect(acks, [id]);
  });

  test('an older or equal version does not replace a newer one', () async {
    await group();
    recorded(9);
    await deliver(alice, topic('newest', 9));
    recorded(7);
    await deliver(alice, topic('older', 7));
    expect((await stored())?.topic, 'newest');
    recorded(9);
    final again = await deliver(alice, topic('same version again', 9));
    expect((await stored())?.topic, 'newest');
    expect(acks, contains(again));
    expect(errors, isEmpty);
  });

  test('an empty topic clears it', () async {
    await group();
    recorded(1);
    await deliver(alice, topic('first', 1));
    recorded(2);
    await deliver(alice, topic('', 2));
    final t = await stored();
    expect(t?.topic, '');
    expect(t?.version, 2);
  });

  test('an unknown group is created from a valid topic, unread 0', () async {
    recorded(5);
    final id = await deliver(alice, topic('A new topic group', 5));
    final c = await (bob.db.select(
      bob.db.conversations,
    )..where((c) => c.id.equals('g'))).getSingle();
    expect(c.type, 'group');
    expect(c.title, 'Brno trip');
    expect(c.unreadCount, 0);
    expect((await stored())?.topic, 'A new topic group');
    expect(await messageRows(), 0);
    expect(acks, [id]);
  });

  test('an unknown group is NOT created from an invalid topic', () async {
    recorded(6);
    await deliver(alice, topic('x', 5));
    expect(await bob.db.select(bob.db.conversations).get(), isEmpty);
  });

  test('a redelivery is acked by the control marker', () async {
    await group();
    recorded(5);
    final fields = {'v': 1, 'id': 'dup', 'groupId': 'g', ...topic('t', 5)};
    final envelope = await alice.sessions.encryptMessage(
      bob.id,
      jsonEncode(fields),
    );
    await deliver(alice, const {}, id: 'dup', envelope: envelope);
    final calls = api.calls;
    await deliver(alice, const {}, id: 'dup', envelope: envelope);
    expect(acks, ['dup', 'dup']);
    expect(api.calls, calls, reason: 'the marker acks before decrypting');
    expect(errors, isEmpty);
  });

  test('a network error leaves it queued; the redelivery applies', () async {
    await group();
    recorded(5);
    api.error = DioException(
      requestOptions: RequestOptions(path: '/groups/g'),
      type: DioExceptionType.connectionError,
    );
    final fields = {'v': 1, 'id': 'net', 'groupId': 'g', ...topic('t', 5)};
    final envelope = await alice.sessions.encryptMessage(
      bob.id,
      jsonEncode(fields),
    );
    await deliver(alice, const {}, id: 'net', envelope: envelope);
    expect(acks, isEmpty);
    expect(errors, hasLength(1));
    expect(await stored(), isNull);
    // The transaction rolled back with the ratchet step, so the queued copy
    // the server sends again still decrypts.
    api.error = null;
    await deliver(alice, const {}, id: 'net', envelope: envelope);
    expect(acks, ['net']);
    expect((await stored())?.topic, 't');
  });

  test('403 from the server check is permanent: dropped and acked', () async {
    await group();
    api.error = DioException(
      requestOptions: RequestOptions(path: '/groups/g'),
      response: Response(
        requestOptions: RequestOptions(path: '/groups/g'),
        statusCode: 403,
      ),
      type: DioExceptionType.badResponse,
    );
    final id = await deliver(alice, topic('t', 5));
    expect(acks, [id]);
    expect(await stored(), isNull);
  });

  test('a malformed stored value reads as no topic and is replaced', () async {
    await group();
    await bob.db
        .into(bob.db.backupState)
        .insert(
          BackupStateCompanion.insert(
            key: groupTopicKey('g'),
            value: '{broken',
          ),
        );
    expect(await stored(), isNull);
    recorded(3);
    await deliver(alice, topic('fixed', 3));
    expect((await stored())?.topic, 'fixed');
  });

  test('without an API the topic cannot be verified and is dropped', () async {
    // A second inbox on a fresh device with no API client.
    final dave = await TestDevice.create('dave');
    final input = StreamController<Map<String, dynamic>>();
    final daveAcks = <String>[];
    final daveInbox = MessageInboxService(
      database: dave.db,
      sessionManager: dave.sessions,
      directory: () => dave.directory,
      incomingMessages: input.stream,
      acknowledge: (_, id) async => daveAcks.add(id),
    )..start();
    await alice.sessions.initiateSession(dave.id, await dave.keyBundle());
    final envelope = await alice.sessions.encryptMessage(
      dave.id,
      jsonEncode({'v': 1, 'id': 'x', 'groupId': 'g', ...topic('t', 5)}),
    );
    input.add({
      'messageId': 'x',
      'senderId': alice.id,
      'encryptedBody': base64Encode(utf8.encode(envelope)),
      'groupId': 'g',
    });
    await Future<void>.delayed(Duration.zero);
    await MessageProcessingQueue.forDatabase(dave.db).run(() async {});
    expect(daveAcks, ['x']);
    expect(await readGroupTopic(dave.db, 'g'), isNull);
    await daveInbox.dispose();
    await input.close();
    await dave.close();
  });
}
