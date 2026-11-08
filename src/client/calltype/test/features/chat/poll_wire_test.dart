import 'dart:convert';

import 'package:calltype_core/storage/database.dart';
import 'package:calltype/features/chat/chat_controller.dart';
import 'package:calltype/features/chat/message_inbox_service.dart';
import 'package:calltype/features/chat/polls.dart';
import 'package:calltype/l10n/l10n.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_multi_device_server.dart';
import '../../helpers/test_device.dart';

/// What a poll looks like ON THE WIRE (spec 2026-11-08-chat-extras): `text`
/// with a readable fallback body for old clients plus the `poll` object.
/// The flow tests only see the receiving side, which hides the shape.
const _aliceId = 'a0000000-0000-4000-8000-000000000001';
const _bobId = 'b0000000-0000-4000-8000-000000000001';

/// `GET /groups/{id}` and friends answer "not business".
class _Api extends FakeDeviceApi {
  _Api(super.server);

  @override
  Dio get transport => Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) => handler.resolve(
          Response(requestOptions: options, data: <String, dynamic>{}),
        ),
      ),
    );
}

/// Records what is handed to the hub instead of delivering it.
class _CapturingHub extends FakeHubClient {
  _CapturingHub(super.server, super.deviceId);
  final sent = <Map<String, String>>[];

  @override
  Future<void> sendDirectFanout(
    String recipientIdentityId,
    Map<String, String> encryptedPayloads, {
    required String messageId,
  }) async => sent.add(encryptedPayloads);
}

void main() {
  test('a poll is sent as text + fallback body + poll object', () async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final server = FakeMultiDeviceServer();
    final alice = await TestDevice.create(_aliceId);
    final bob = await TestDevice.create(_bobId);
    server
      ..add(alice)
      ..add(bob);
    final hub = _CapturingHub(server, _aliceId);
    final directory = server.directoryFor(alice);
    final inbox = MessageInboxService(
      database: alice.db,
      sessionManager: alice.sessions,
      incomingMessages: const Stream.empty(),
      directory: () => directory,
    );
    addTearDown(() async {
      await inbox.dispose();
      hub.dispose();
      await server.close();
      await alice.close();
      await bob.close();
    });
    await alice.db
        .into(alice.db.conversations)
        .insert(ConversationsCompanion.insert(id: _bobId, type: 'direct'));
    final chat = ChatController(
      database: alice.db,
      signalRClient: hub,
      sessionManager: alice.sessions,
      inbox: inbox,
      apiClient: _Api(server),
      conversationId: _bobId,
      directory: directory,
    );
    addTearDown(chat.dispose);
    final lunch = PollPayload.create(
      question: 'Lunch?',
      options: ['Pizza', 'Sushi'],
    );

    expect(await chat.sendPoll(lunch), isTrue);

    final envelope = hub.sent.single[_bobId]!;
    final plaintext = await bob.sessions.decryptMessage(
      _aliceId,
      utf8.decode(base64Decode(envelope)),
    );
    final payload = jsonDecode(plaintext) as Map<String, dynamic>;
    final english = lookupAppLocalizations(const Locale('en'));
    expect(payload['type'], 'text');
    expect(payload['body'], lunch.fallbackText(english.pollFallbackUpdate));
    expect(payload['body'], contains('Lunch?'));
    expect(payload['body'], contains('Pizza'));
    expect(payload[pollKey], lunch.toJson());
    expect(payload['to'], _bobId);
    // The local row stays a poll and is marked sent.
    final row = await alice.db.select(alice.db.messages).getSingle();
    expect(row.type, pollMessageType);
    expect(row.status, 'sent');
  });
}
