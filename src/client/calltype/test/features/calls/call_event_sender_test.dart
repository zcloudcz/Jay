import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype/core/network/signalr_client.dart';
import 'package:calltype/core/network/webrtc_manager.dart';
import 'package:calltype/features/calls/call_event_sender.dart';
import 'package:calltype/features/chat/message_inbox_service.dart';
import '../../helpers/test_device.dart';

class SenderApi extends ApiClient {
  SenderApi(this.peers) : super(baseUrl: 'http://unused');
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

class SenderTransport extends SignalRClient {
  SenderTransport() : super(baseUrl: 'http://unused', deviceId: 'alice');
  bool fail = false;
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
    if (fail) throw StateError('offline at hang-up');
  }
}

void main() {
  test(
    'sends exactly one call-event with the exact 6-key body the archiver expects',
    () async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      final alice = await TestDevice.create('alice');
      final bob = await TestDevice.create('bob');
      final transport = SenderTransport();
      final api = SenderApi([bob]);
      final reports = StreamController<CallReport>();
      final sender = CallEventSender(
        database: alice.db,
        signalRClient: transport,
        sessionManager: alice.sessions,
        apiClient: api,
        callReports: reports.stream,
      );
      sender.start();
      final startedAt = DateTime.utc(2026, 1, 1, 10);
      final endedAt = startedAt.add(const Duration(minutes: 3));
      reports.add(
        CallReport(
          callId: 'call-1',
          businessGroupId: 'group',
          role: 'caller',
          peerDeviceId: 'bob',
          startedAt: startedAt,
          endedAt: endedAt,
          media: 'audio',
          outcome: 'completed',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(transport.envelopes, hasLength(1));
      // Envelopes go to recipients other than the sender (self is stored
      // locally, not sent to itself) — same convention as an ordinary group
      // message.
      expect(transport.envelopes.single.keys, ['bob']);

      // Decrypt bob's envelope to check the exact body shape the archiver
      // (jay_archiver/group_message_source) validates strictly.
      final envelope = utf8.decode(
        base64Decode(transport.envelopes.single['bob']!),
      );
      final plaintext = await bob.sessions.decryptMessage('alice', envelope);
      final outer = jsonDecode(plaintext) as Map<String, dynamic>;
      expect(outer['type'], 'call-event');
      final body = jsonDecode(outer['body'] as String) as Map<String, dynamic>;
      expect(
        body.keys.toSet(),
        {
          'callId',
          'role',
          'peerDeviceId',
          'startedAt',
          'endedAt',
          'media',
          'outcome',
        },
      );
      expect(body['callId'], 'call-1');
      expect(body['role'], 'caller');
      expect(body['peerDeviceId'], 'bob');
      expect(body['media'], 'audio');
      expect(body['outcome'], 'completed');

      // The sender's own copy is stored locally too, rendered the same way.
      final own = await (alice.db.select(
        alice.db.messages,
      )..where((m) => m.conversationId.equals('group'))).getSingle();
      expect(own.type, 'call-event');
      expect(own.status, 'sent');

      await alice.close();
      await bob.close();
    },
  );

  test('a failed send leaves the report queued (failed) rather than lost', () async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final alice = await TestDevice.create('alice');
    final bob = await TestDevice.create('bob');
    final transport = SenderTransport()..fail = true;
    final api = SenderApi([bob]);
    final reports = StreamController<CallReport>();
    final sender = CallEventSender(
      database: alice.db,
      signalRClient: transport,
      sessionManager: alice.sessions,
      apiClient: api,
      callReports: reports.stream,
    );
    sender.start();
    reports.add(
      CallReport(
        callId: 'call-2',
        businessGroupId: 'group',
        role: 'callee',
        peerDeviceId: 'bob',
        startedAt: DateTime.now(),
        endedAt: DateTime.now(),
        media: 'video',
        outcome: 'failed',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final row = await (alice.db.select(
      alice.db.messages,
    )..where((m) => m.conversationId.equals('group'))).getSingle();
    expect(row.status, 'failed');
    // Never silently dropped: still there for a future retry mechanism.
    expect(row.type, 'call-event');

    await alice.close();
    await bob.close();
  });

  test('incoming call-event does not crash the inbox and skips unread bump', () async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final alice = await TestDevice.create('alice');
    final bob = await TestDevice.create('bob');
    await bob.sessions.initiateSession('alice', await alice.keyBundle());
    final body = jsonEncode({
      'callId': 'call-3',
      'role': 'caller',
      'peerDeviceId': 'alice',
      'startedAt': DateTime.now().toUtc().toIso8601String(),
      'endedAt': DateTime.now().toUtc().toIso8601String(),
      'media': 'audio',
      'outcome': 'missed',
    });
    final payload = jsonEncode({
      'v': 1,
      'id': 'msg-1',
      'body': body,
      'type': 'call-event',
      'groupId': null,
      'groupName': null,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    });
    final envelope = await bob.sessions.encryptMessage('alice', payload);
    final incoming = StreamController<Map<String, dynamic>>();
    final inbox = MessageInboxService(
      database: alice.db,
      sessionManager: alice.sessions,
      directory: () => alice.directory,
      incomingMessages: incoming.stream,
    );
    inbox.start();
    incoming.add({
      'senderId': 'bob',
      'messageId': 'msg-1',
      'encryptedBody': base64Encode(utf8.encode(envelope)),
    });
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final row = await (alice.db.select(
      alice.db.messages,
    )..where((m) => m.id.equals('msg-1'))).getSingle();
    expect(row.type, 'call-event');
    final conversation = await (alice.db.select(
      alice.db.conversations,
    )..where((c) => c.id.equals('bob'))).getSingle();
    expect(conversation.unreadCount, 0);

    await inbox.dispose();
    await alice.close();
    await bob.close();
  });
}
