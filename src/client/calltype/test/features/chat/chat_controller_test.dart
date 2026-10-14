import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:calltype/core/network/api_client.dart';
import 'package:calltype/core/network/signalr_client.dart';
import 'package:calltype/core/storage/database.dart';
import 'package:calltype/features/chat/chat_controller.dart';
import 'package:calltype/features/chat/attachment.dart';
import 'package:calltype/features/chat/message_inbox_service.dart';
import '../../helpers/test_device.dart';

class ChatApi extends ApiClient {
  ChatApi(this.peers) : super(baseUrl: 'http://unused');
  final List<TestDevice> peers;
  @override
  Future<List<String>> getGroupMembers(String id) async => [
    'alice',
    ...peers.map((p) => p.id),
  ];
  @override
  Future<Map<String, dynamic>> getKeyBundle(String id) =>
      peers.firstWhere((p) => p.id == id).keyBundle();
}

class Transport extends SignalRClient {
  Transport() : super(baseUrl: 'http://unused', deviceId: 'alice');
  bool fail = true;
  // W2-F: lets a test simulate the hub rejecting the send with a specific
  // HubException message ('audit_recipient_missing' or 'auditor_unavailable')
  // instead of the generic connectivity failure `fail` produces.
  String failMessage = 'lost acceptance response';
  final envelopes = <Map<String, String>>[];
  final ids = <String?>[];
  @override
  Future<void> sendGroupMessage(
    String groupId,
    Map<String, String> encryptedPayloads, {
    String? messageId,
  }) async {
    envelopes.add(Map.of(encryptedPayloads));
    ids.add(messageId);
    if (fail) throw StateError(failMessage);
  }

  // P1: a 1:1 send goes through sendMessage, not sendGroupMessage — needed
  // to simulate the hub rejecting it with business_conversation_required.
  @override
  Future<void> sendMessage(
    String recipientDeviceId,
    String encryptedBodyBase64, {
    String? messageId,
  }) async {
    envelopes.add({recipientDeviceId: encryptedBodyBase64});
    ids.add(messageId);
    if (fail) throw StateError(failMessage);
  }
}

void main() {
  test(
    'group retries preserve UUID and recipient ciphertext after restart',
    () async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      final alice = await TestDevice.create('alice');
      final bob = await TestDevice.create('bob');
      final carol = await TestDevice.create('carol');
      final transport = Transport();
      final inbox = MessageInboxService(
        database: alice.db,
        sessionManager: alice.sessions,
        directory: () => alice.directory,
        incomingMessages: const Stream.empty(),
      );
      await alice.db
          .into(alice.db.conversations)
          .insert(
            ConversationsCompanion.insert(
              id: 'group',
              type: 'group',
              title: const Value('Team'),
            ),
          );
      ChatController controller() => ChatController(
        database: alice.db,
        signalRClient: transport,
        sessionManager: alice.sessions,
        inbox: inbox,
        apiClient: ChatApi([bob, carol]),
        conversationId: 'group',
        directory: alice.directory,
      );
      final first = controller();
      await first.sendMessage('hello team');
      final failed = await alice.db.select(alice.db.messages).getSingle();
      expect(failed.status, 'failed');
      // One hub call carries the whole fan-out (KB2 needs the auditor's
      // envelope in every call, so it can never be split per recipient).
      expect(transport.envelopes.single.keys.toSet(), {'bob', 'carol'});
      first.dispose();
      transport.fail = false;
      final second = controller();
      await second.retryMessage(failed.id);
      expect(transport.ids, [failed.id, failed.id]);
      expect(transport.envelopes[1], transport.envelopes[0]);
      expect(
        (await alice.db.select(alice.db.messages).getSingle()).status,
        'sent',
      );
      expect(
        await (alice.db.select(
          alice.db.backupState,
        )..where((s) => s.key.like('outbox:%'))).get(),
        isEmpty,
      );
      for (final peer in [bob, carol]) {
        final plaintext = await peer.sessions.decryptMessage(
          alice.id,
          utf8.decode(
            base64Decode(
              transport.envelopes.lastWhere(
                (entry) => entry.containsKey(peer.id),
              )[peer.id]!,
            ),
          ),
        );
        expect(jsonDecode(plaintext), containsPair('groupId', 'group'));
        expect(jsonDecode(plaintext), containsPair('groupName', 'Team'));
        expect(jsonDecode(plaintext), containsPair('body', 'hello team'));
      }
      await second.sendAttachment('limit.bin', Uint8List(Attachment.maxBytes));
      final fileEnvelope = transport.envelopes.lastWhere(
        (entry) => entry.containsKey(bob.id),
      )[bob.id]!;
      expect(fileEnvelope.length, greaterThan(512 * 1024));
      expect(fileEnvelope.length, lessThanOrEqualTo(768 * 1024));
      final filePayload =
          jsonDecode(
                await bob.sessions.decryptMessage(
                  alice.id,
                  utf8.decode(base64Decode(fileEnvelope)),
                ),
              )
              as Map<String, dynamic>;
      expect(filePayload['type'], 'file');
      expect(
        Attachment.decode(filePayload['body'] as String).bytes.length,
        Attachment.maxBytes,
      );
      second.dispose();
      await inbox.dispose();
      transport.dispose();
      await alice.close();
      await bob.close();
      await carol.close();
    },
  );

  test(
    // E05 KB1 regression: the fan-out must never skip a member the server
    // returned — the auditor is just another entry in that list, added by
    // the server on group creation. If a future change filtered members by
    // role or type, this would catch it going missing from the envelope.
    'business group send fans out to every server-reported member, including the auditor',
    () async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      final alice = await TestDevice.create('alice');
      final auditor = await TestDevice.create('auditor-device');
      final transport = Transport()..fail = false;
      final inbox = MessageInboxService(
        database: alice.db,
        sessionManager: alice.sessions,
        directory: () => alice.directory,
        incomingMessages: const Stream.empty(),
      );
      await alice.db
          .into(alice.db.conversations)
          .insert(
            ConversationsCompanion.insert(
              id: 'biz-group',
              type: 'group',
              title: const Value('Acme Deal'),
              organizationId: const Value('org1'),
              organizationName: const Value('Acme'),
            ),
          );
      final controller = ChatController(
        database: alice.db,
        signalRClient: transport,
        sessionManager: alice.sessions,
        inbox: inbox,
        apiClient: ChatApi([auditor]),
        conversationId: 'biz-group',
        directory: alice.directory,
      );

      await controller.sendMessage('deal terms attached');

      expect(transport.envelopes.single.keys, contains('auditor-device'));
      expect(controller.consumeAuditRecipientMissing(), isFalse);

      controller.dispose();
      await inbox.dispose();
      transport.dispose();
      await alice.close();
      await auditor.close();
    },
  );

  test(
    // W2-F: the hub rejects a business send with a plain-text HubException
    // whose message contains 'auditor_unavailable' when the organization's
    // auditor is dead. This is deliberately a SEPARATE flag from
    // auditRecipientMissing (KB2) — same transport-level signal, different
    // user-facing wording, so the two must not collapse into one flag.
    'business group send sets auditorUnavailable (not auditRecipientMissing) on auditor_unavailable',
    () async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      final alice = await TestDevice.create('alice');
      final auditor = await TestDevice.create('auditor-device');
      final transport = Transport()
        ..fail = true
        ..failMessage = 'auditor_unavailable';
      final inbox = MessageInboxService(
        database: alice.db,
        sessionManager: alice.sessions,
        directory: () => alice.directory,
        incomingMessages: const Stream.empty(),
      );
      await alice.db
          .into(alice.db.conversations)
          .insert(
            ConversationsCompanion.insert(
              id: 'biz-group',
              type: 'group',
              title: const Value('Acme Deal'),
              organizationId: const Value('org1'),
              organizationName: const Value('Acme'),
            ),
          );
      final controller = ChatController(
        database: alice.db,
        signalRClient: transport,
        sessionManager: alice.sessions,
        inbox: inbox,
        apiClient: ChatApi([auditor]),
        conversationId: 'biz-group',
        directory: alice.directory,
      );

      await controller.sendMessage('deal terms attached');

      expect(controller.consumeAuditorUnavailable(), isTrue);
      expect(controller.consumeAuditRecipientMissing(), isFalse);
      expect(
        (await alice.db.select(alice.db.messages).getSingle()).status,
        'failed',
      );

      controller.dispose();
      await inbox.dispose();
      transport.dispose();
      await alice.close();
      await auditor.close();
    },
  );

  test(
    // P1: a 1:1 send rejected with business_conversation_required is a
    // DIFFERENT flag from auditRecipientMissing/auditorUnavailable — it's a
    // redirect (open the business conversation), not a retryable failure.
    'business_conversation_required on a 1:1 send sets its own flag only',
    () async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      final alice = await TestDevice.create('alice');
      final bob = await TestDevice.create('bob');
      final transport = Transport()
        ..fail = true
        ..failMessage = 'business_conversation_required';
      final inbox = MessageInboxService(
        database: alice.db,
        sessionManager: alice.sessions,
        directory: () => alice.directory,
        incomingMessages: const Stream.empty(),
      );
      await alice.db
          .into(alice.db.conversations)
          .insert(
            ConversationsCompanion.insert(id: bob.id, type: 'direct'),
          );
      final controller = ChatController(
        database: alice.db,
        signalRClient: transport,
        sessionManager: alice.sessions,
        inbox: inbox,
        apiClient: ChatApi([bob]),
        conversationId: bob.id,
        directory: alice.directory,
      );

      await controller.sendMessage('hey');

      expect(controller.consumeBusinessConversationRequired(), isTrue);
      expect(controller.consumeAuditRecipientMissing(), isFalse);
      expect(controller.consumeAuditorUnavailable(), isFalse);
      expect(
        (await alice.db.select(alice.db.messages).getSingle()).status,
        'failed',
      );

      controller.dispose();
      await inbox.dispose();
      transport.dispose();
      await alice.close();
      await bob.close();
    },
  );

  test('on a companion, own messages are stored under the identity id', () async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final web = await TestDevice.create('web');
    final bob = await TestDevice.create('bob');
    // What a verified list leaves behind: 'web' belongs to identity 'phone'.
    await web.db
        .into(web.db.knownDeviceListMembers)
        .insert(
          KnownDeviceListMembersCompanion.insert(
            deviceId: 'web',
            primaryDeviceId: 'phone',
          ),
        );
    await web.directory.load();
    await web.db
        .into(web.db.conversations)
        .insert(ConversationsCompanion.insert(id: bob.id, type: 'direct'));
    final transport = Transport()..fail = true;
    final inbox = MessageInboxService(
      database: web.db,
      sessionManager: web.sessions,
      directory: () => web.directory,
      incomingMessages: const Stream.empty(),
    );
    final controller = ChatController(
      database: web.db,
      signalRClient: transport,
      sessionManager: web.sessions,
      inbox: inbox,
      apiClient: ChatApi([bob]),
      conversationId: bob.id,
      directory: web.directory,
    );

    expect(controller.myIdentityId, 'phone');
    expect(controller.isCompanion, isTrue);
    await controller.sendMessage('hi');
    expect((await web.db.select(web.db.messages).getSingle()).senderId, 'phone');

    controller.dispose();
    await inbox.dispose();
    transport.dispose();
    await web.close();
    await bob.close();
  });
}
