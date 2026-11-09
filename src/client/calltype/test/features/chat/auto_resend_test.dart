import 'dart:async';

import 'package:calltype/features/chat/attachment_media.dart';
import 'package:calltype/features/chat/chat_controller.dart';
import 'package:calltype/features/chat/message_inbox_service.dart';
import 'package:calltype/features/chat/message_sender.dart';
import 'package:calltype/features/chat/resend_service.dart';
import 'package:calltype/features/media/media_service.dart';
import 'package:calltype/features/media/media_store_memory.dart';
import 'package:calltype_core/devices/device_directory.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_multi_device_server.dart';
import '../../helpers/test_device.dart';
import '../media/media_fakes.dart';

/// Automatic resend of failed messages end to end (spec
/// 2026-11-09-auto-resend-read-sync, part 1): real databases, ratchets,
/// inboxes, chat controllers and the app-wide ResendService; only the hub
/// is the in-memory fake server and the clock is fake. A has a phone
/// (primary) and a linked web device; B is a contact.
const aPhoneId = 'a0000000-0000-4000-8000-000000000001';
const aWebId = 'a0000000-0000-4000-8000-000000000002';
const bobId = 'b0000000-0000-4000-8000-000000000001';

/// The tests drive ResendService.runDue with a fake clock; no real timer
/// may run a pass in between.
Timer _noTimer(Duration wait, void Function() callback) =>
    Timer(const Duration(days: 365), () {});

/// A hub whose next [failures] sends throw [error] (network down by
/// default); [calls] counts every send, [duplicate] delivers every
/// successful send twice (a lost ack: same envelope again).
class _FlakyHub extends FakeHubClient {
  _FlakyHub(super.server, super.deviceId);

  int failures = 0;
  String error = 'Connection closed before the invocation completed';
  int calls = 0;
  bool duplicate = false;

  @override
  Future<void> sendDirectFanout(
    String recipientIdentityId,
    Map<String, String> encryptedPayloads, {
    required String messageId,
  }) async {
    calls++;
    if (failures > 0) {
      failures--;
      throw Exception(error);
    }
    await super.sendDirectFanout(
      recipientIdentityId,
      encryptedPayloads,
      messageId: messageId,
    );
    if (duplicate) {
      await super.sendDirectFanout(
        recipientIdentityId,
        encryptedPayloads,
        messageId: messageId,
      );
    }
  }
}

class _Node {
  _Node(this.device, this.server, {DateTime Function()? clock})
    : hub = _FlakyHub(server, device.id),
      media = MediaService(
        remote: FakeMediaRemote(),
        store: MemoryMediaStore(),
        web: false,
      ) {
    directory = server.directoryFor(device);
    inbox = MessageInboxService(
      database: device.db,
      sessionManager: device.sessions,
      incomingMessages: server.inboxes[device.id]!.stream,
      directory: () => directory,
      apiClient: FakeDeviceApi(server),
      acknowledge: hub.acknowledgeMessage,
    )..start();
    resend = ResendService(
      database: device.db,
      sender: () => MessageSender(
        database: device.db,
        signalRClient: hub,
        sessionManager: device.sessions,
        apiClient: FakeDeviceApi(server),
        directory: directory,
        media: media,
      ),
      selfIdentityId: () => directory.selfIdentityId,
      clock: clock,
      timer: _noTimer,
    );
  }

  final TestDevice device;
  final FakeMultiDeviceServer server;
  final _FlakyHub hub;
  final MediaService media;
  late final DeviceDirectory directory;
  late final MessageInboxService inbox;
  late final ResendService resend;

  ChatController chat(String conversationId) => ChatController(
    database: device.db,
    signalRClient: hub,
    sessionManager: device.sessions,
    inbox: inbox,
    apiClient: FakeDeviceApi(server),
    conversationId: conversationId,
    directory: directory,
    media: media,
    resend: resend,
  );

  AppDatabase get db => device.db;

  Future<List<Message>> messages() => db.select(db.messages).get();

  Future<Message?> message(String id) =>
      (db.select(db.messages)..where((m) => m.id.equals(id))).getSingleOrNull();

  Future<String?> sendFail(String id) async =>
      (await (db.select(db.backupState)
                ..where((s) => s.key.equals('$sendFailPrefix$id')))
              .getSingleOrNull())
          ?.value;

  Future<void> settle() =>
      MessageProcessingQueue.forDatabase(db).run(() async {});

  Future<void> close() async {
    resend.dispose();
    await inbox.dispose();
    hub.dispose();
  }
}

void main() {
  late FakeMultiDeviceServer server;
  late _Node aPhone;
  late _Node aWeb;
  late _Node bob;
  late DateTime now;

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
    now = DateTime.now();
    server = FakeMultiDeviceServer();
    final devices = [
      for (final id in [aPhoneId, aWebId, bobId]) await TestDevice.create(id),
    ];
    devices.forEach(server.add);
    aPhone = _Node(devices[0], server, clock: () => now);
    aWeb = _Node(devices[1], server);
    bob = _Node(devices[2], server);
    await server.link(aPhone.device, [aWeb.device], version: 1);
    await aPhone.directory.refresh(aPhoneId, ensurePinned: (_) async {});
    await aWeb.directory.refresh(
      aPhoneId,
      ensurePinned: server.pinFor(aWeb.device),
    );
    await aPhone.db
        .into(aPhone.db.conversations)
        .insert(ConversationsCompanion.insert(id: bobId, type: 'direct'));
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

  /// A sends [text] to B from an open chat; returns the row.
  Future<Message> send(String text, {ChatController? chat}) async {
    final controller = chat ?? aPhone.chat(bobId);
    if (chat == null) addTearDown(controller.dispose);
    await controller.sendMessage(text);
    await settle();
    return (await aPhone.messages()).firstWhere((m) => m.body == text);
  }

  int acksOf(_Node node, String id) =>
      node.hub.acks.where((a) => a == id).length;

  test('a failed message goes out by itself after the backoff, delivered '
      'exactly once', () async {
    aPhone.hub.failures = 2;
    final chat = aPhone.chat(bobId);
    addTearDown(chat.dispose);
    final first = await send('hello?', chat: chat);
    expect(first.status, 'failed');
    expect(aPhone.resend.dueAt(first.id), now.add(const Duration(seconds: 5)));
    await watchers();
    expect(
      chat.retryPending(first),
      isTrue,
      reason: 'shown as sending while a resend is pending (R8)',
    );

    now = now.add(const Duration(seconds: 5));
    await aPhone.resend.runDue();
    expect((await aPhone.message(first.id))!.status, 'failed');
    expect(aPhone.hub.calls, 2);

    now = now.add(const Duration(seconds: 10));
    await aPhone.resend.runDue();
    expect(aPhone.hub.calls, 2, reason: 'second step is 15 s');

    now = now.add(const Duration(seconds: 5));
    await aPhone.resend.runDue();
    await settle();
    expect((await aPhone.message(first.id))!.status, 'sent');
    expect(aPhone.resend.dueAt(first.id), isNull);
    expect((await bob.messages()).single.body, 'hello?');
    expect(acksOf(bob, first.id), 1, reason: 'one envelope, one delivery');
    expect((await aWeb.messages()).single.status, 'sent');
  });

  test('backoff is 5 s, 15 s, 1 min, 5 min, then every 15 min', () async {
    aPhone.hub.failures = 1000;
    final row = await send('down');
    var calls = aPhone.hub.calls;
    for (final step in const [
      Duration(seconds: 5),
      Duration(seconds: 15),
      Duration(minutes: 1),
      Duration(minutes: 5),
      Duration(minutes: 15),
      Duration(minutes: 15),
    ]) {
      final due = aPhone.resend.dueAt(row.id)!;
      expect(due.difference(now), step);
      now = due.subtract(const Duration(seconds: 1));
      await aPhone.resend.runDue();
      expect(aPhone.hub.calls, calls, reason: 'not before $step');
      now = due;
      await aPhone.resend.runDue();
      expect(aPhone.hub.calls, ++calls);
    }
  });

  test('a manual retry always runs and resets the backoff', () async {
    aPhone.hub.failures = 1000;
    final chat = aPhone.chat(bobId);
    addTearDown(chat.dispose);
    final row = await send('down', chat: chat);
    for (var i = 0; i < 3; i++) {
      now = aPhone.resend.dueAt(row.id)!;
      await aPhone.resend.runDue();
    }
    expect(
      aPhone.resend.dueAt(row.id)!.difference(now),
      const Duration(minutes: 5),
    );
    await chat.retryMessage(row.id);
    expect(
      aPhone.resend.dueAt(row.id)!.difference(now),
      const Duration(seconds: 5),
    );
  });

  test(
    'a permanent failure is never resent and keeps the manual button',
    () async {
      aPhone.hub
        ..failures = 1
        ..error = 'HubException: business_conversation_required';
      final chat = aPhone.chat(bobId);
      addTearDown(chat.dispose);
      final row = await send('hi', chat: chat);
      expect(row.status, 'failed');
      expect(await aPhone.sendFail(row.id), 'business_conversation_required');
      expect(chat.consumeBusinessConversationRequired(), isTrue);
      expect(aPhone.resend.dueAt(row.id), isNull);

      now = now.add(const Duration(hours: 1));
      await aPhone.resend.trigger();
      expect(aPhone.hub.calls, 1);
      await watchers();
      expect(chat.retryPending((await aPhone.message(row.id))!), isFalse);

      // The user decides: a manual retry still works.
      await chat.retryMessage(row.id);
      await settle();
      expect((await aPhone.message(row.id))!.status, 'sent');
      expect(await aPhone.sendFail(row.id), isNull);
    },
  );

  test(
    'the code\'s permanent errors are classified, the rest is transient',
    () {
      expect(permanentSendFailure(const MediaCancelled()), 'media_cancelled');
      expect(
        permanentSendFailure(const PermanentSendError('conversation_missing')),
        'conversation_missing',
      );
      expect(
        permanentSendFailure(
          Exception(
            'HubException: Sender and recipients must be group members',
          ),
        ),
        'not_a_member',
      );
      expect(
        permanentSendFailure(
          Exception('HubException: audit_recipient_missing'),
        ),
        'audit_recipient_missing',
      );
      for (final transient in [
        Exception('HubException: auditor_unavailable'),
        Exception('HubException: device_list_stale:a,b'),
        Exception('Connection closed'),
        StateError('network down'),
      ]) {
        expect(permanentSendFailure(transient), isNull, reason: '$transient');
      }
    },
  );

  test('after 24 h only the manual button is left', () async {
    aPhone.hub.failures = 1000;
    final chat = aPhone.chat(bobId);
    addTearDown(chat.dispose);
    final row = await send('late', chat: chat);
    final calls = aPhone.hub.calls;
    now = row.createdAt.add(ResendService.giveUpAfter);
    await aPhone.resend.trigger();
    expect(aPhone.hub.calls, calls);
    expect(await aPhone.sendFail(row.id), sendFailExpired);
    expect((await aPhone.message(row.id))!.status, 'failed');
    await watchers();
    expect(chat.retryPending((await aPhone.message(row.id))!), isFalse);
  });

  test('a reconnect resends at once, also in a chat that is not open; two '
      'triggers at once send once', () async {
    aPhone.hub.failures = 1;
    final chat = aPhone.chat(bobId);
    final row = await send('from a closed chat', chat: chat);
    chat.dispose();
    expect(row.status, 'failed');
    await Future.wait([
      aPhone.resend.trigger(),
      aPhone.resend.trigger(),
      aPhone.resend.runDue(all: true),
    ]);
    await settle();
    expect((await aPhone.message(row.id))!.status, 'sent');
    expect(aPhone.hub.calls, 2, reason: 'one failure, one resend');
    expect(acksOf(bob, row.id), 1);
  });

  test(
    'a sending leftover of a killed app is taken over after 2 minutes',
    () async {
      // Encrypted and stored, but the app died before the hub call ended.
      aPhone.hub.failures = 1;
      final row = await send('in flight');
      await (aPhone.db.update(aPhone.db.messages)
            ..where((m) => m.id.equals(row.id)))
          .write(const MessagesCompanion(status: Value('sending')));
      // The old process is gone with its schedule.
      aPhone.resend.dispose();
      final restarted = ResendService(
        database: aPhone.db,
        sender: () => MessageSender(
          database: aPhone.db,
          signalRClient: aPhone.hub,
          sessionManager: aPhone.device.sessions,
          apiClient: FakeDeviceApi(server),
          directory: aPhone.directory,
        ),
        selfIdentityId: () => aPhoneId,
        clock: () => now,
        timer: _noTimer,
      );
      addTearDown(restarted.dispose);
      await restarted.trigger();
      expect(aPhone.hub.calls, 1, reason: 'may still be a first send');
      // createdAt keeps whole seconds and may round past the test's start.
      now = row.createdAt.add(ResendService.orphanAge);
      await restarted.trigger();
      await settle();
      expect((await aPhone.message(row.id))!.status, 'sent');
      expect(acksOf(bob, row.id), 1);
    },
  );

  test(
    'a leftover delete control row is sent and finishes the delete',
    () async {
      final original = await send('oops');
      await settle();
      expect((await bob.messages()).single.body, 'oops');
      await aPhone.db
          .into(aPhone.db.messages)
          .insert(
            MessagesCompanion.insert(
              id: 'ctl-1',
              conversationId: bobId,
              senderId: aPhoneId,
              body: Value(original.id),
              type: const Value('delete'),
              status: const Value('sending'),
              createdAt: now.subtract(const Duration(minutes: 3)),
            ),
          );
      await aPhone.resend.trigger();
      await settle();
      expect((await aPhone.message('ctl-1')), isNull);
      expect((await aPhone.message(original.id))!.deleted, isTrue);
      expect((await bob.messages()).single.deleted, isTrue);
    },
  );

  test('a control row held by its flow is never touched', () async {
    final registry = OutboxRegistry.forDatabase(aPhone.db);
    await aPhone.db
        .into(aPhone.db.messages)
        .insert(
          MessagesCompanion.insert(
            id: 'ctl-held',
            conversationId: bobId,
            senderId: aPhoneId,
            body: const Value('x'),
            type: const Value('delete'),
            status: const Value('failed'),
            createdAt: now.subtract(const Duration(minutes: 3)),
          ),
        );
    registry.hold('ctl-held');
    addTearDown(() => registry.release('ctl-held'));
    await aPhone.resend.trigger();
    expect(aPhone.hub.calls, 0);
    expect(await aPhone.message('ctl-held'), isNotNull);
  });

  test('a failed media upload is resumed by the resend', () async {
    final remote = FakeMediaRemote()..failPutAt = 0;
    final media = MediaService(
      remote: remote,
      store: MemoryMediaStore(),
      web: false,
    );
    final resend = ResendService(
      database: aPhone.db,
      sender: () => MessageSender(
        database: aPhone.db,
        signalRClient: aPhone.hub,
        sessionManager: aPhone.device.sessions,
        apiClient: FakeDeviceApi(server),
        directory: aPhone.directory,
        media: media,
      ),
      selfIdentityId: () => aPhoneId,
      clock: () => now,
      timer: _noTimer,
    );
    addTearDown(resend.dispose);
    final chat = ChatController(
      database: aPhone.db,
      signalRClient: aPhone.hub,
      sessionManager: aPhone.device.sessions,
      inbox: aPhone.inbox,
      apiClient: FakeDeviceApi(server),
      conversationId: bobId,
      directory: aPhone.directory,
      media: media,
      resend: resend,
    );
    addTearDown(chat.dispose);
    await chat.sendMedia(
      PickedMedia.bytes(
        'note.txt',
        Uint8List.fromList(List.filled(300, 7)),
        mimeType: 'text/plain',
      ),
    );
    final row = (await aPhone.messages()).single;
    expect(row.status, 'failed');
    expect(aPhone.hub.calls, 0, reason: 'nothing sent before the upload');
    remote.failPutAt = null;
    now = resend.dueAt(row.id)!;
    await resend.runDue();
    await settle();
    expect((await aPhone.message(row.id))!.status, 'sent');
    expect(aPhone.hub.calls, 1);
  });

  test('the same envelope delivered twice is one bubble', () async {
    aPhone.hub.duplicate = true;
    final row = await send('twice');
    await settle();
    expect(acksOf(bob, row.id), 2, reason: 'both deliveries acked');
    expect((await bob.messages()).map((m) => m.id), [row.id]);
    final conversation = await (bob.db.select(
      bob.db.conversations,
    )..where((c) => c.id.equals(aPhoneId))).getSingle();
    expect(conversation.unreadCount, 1);
  });
}
