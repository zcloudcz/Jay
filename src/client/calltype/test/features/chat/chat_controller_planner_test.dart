import 'dart:convert';

import 'package:calltype/core/network/api_client.dart';
import 'package:calltype/core/network/signalr_client.dart';
import 'package:calltype/core/storage/database.dart';
import 'package:calltype/features/chat/chat_controller.dart';
import 'package:calltype/features/chat/message_inbox_service.dart';
import 'package:calltype_core/devices/device_directory.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/test_device.dart';

class _Api extends ApiClient {
  _Api(this.peers) : super(baseUrl: 'http://unused');
  final List<TestDevice> peers;
  @override
  Future<Map<String, dynamic>> getKeyBundle(String id) =>
      peers.firstWhere((p) => p.id == id).keyBundle();
}

class _Hub extends SignalRClient {
  _Hub() : super(baseUrl: 'http://unused', deviceId: 'alice');
  final sent = <List<String?>>[];
  @override
  Future<void> sendMessage(
    String recipientDeviceId,
    String encryptedBodyBase64, {
    String? messageId,
  }) async => sent.add([recipientDeviceId, messageId, encryptedBodyBase64]);
}

/// Two-device peer, as stream D's planner will report it in wave 2.
class _TwoDevicePlanner implements DirectPayloadPlanner {
  @override
  Future<Map<String, String>> plan(
    String conversationId,
    String payloadJson, {
    bool ownDevicesOnly = false,
  }) async => {'bob': payloadJson, 'bob-laptop': payloadJson};
}

/// D §4.1 point 3: a direct send goes through the planner, is encrypted per
/// device and leaves as one fan-out with a single message id.
void main() {
  test('direct send encrypts one envelope per planned device', () async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final alice = await TestDevice.create('alice');
    final bob = await TestDevice.create('bob');
    final laptop = await TestDevice.create('bob-laptop');
    final hub = _Hub();
    final inbox = MessageInboxService(
      database: alice.db,
      sessionManager: alice.sessions,
      incomingMessages: const Stream.empty(),
    );
    await alice.db
        .into(alice.db.conversations)
        .insert(ConversationsCompanion.insert(id: 'bob', type: 'direct'));
    final controller = ChatController(
      database: alice.db,
      signalRClient: hub,
      sessionManager: alice.sessions,
      inbox: inbox,
      apiClient: _Api([bob, laptop]),
      conversationId: 'bob',
      myDeviceId: alice.id,
      planner: _TwoDevicePlanner(),
    );

    await controller.sendMessage('to both');

    expect(hub.sent.map((s) => s[0]), ['bob', 'bob-laptop']);
    final id = (await alice.db.select(alice.db.messages).getSingle()).id;
    expect(hub.sent.map((s) => s[1]), [id, id]);
    // Each device can decrypt its own envelope.
    for (final (device, envelope) in [
      (bob, hub.sent[0][2]!),
      (laptop, hub.sent[1][2]!),
    ]) {
      final plain = await device.sessions.decryptMessage(
        alice.id,
        utf8.decode(base64Decode(envelope)),
      );
      expect((jsonDecode(plain) as Map)['body'], 'to both');
    }
    expect(
      (await alice.db.select(alice.db.messages).getSingle()).status,
      'sent',
    );

    controller.dispose();
    await inbox.dispose();
    hub.dispose();
    await alice.close();
    await bob.close();
    await laptop.close();
  });
}
