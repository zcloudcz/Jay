import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:calltype/core/storage/database.dart';
import 'package:calltype/features/chat/message_inbox_service.dart';

import '../../helpers/test_device.dart';

/// Tests for the app-wide [MessageInboxService] — the component that
/// guarantees no incoming message is lost, even with no chat screen open.
///
/// Real crypto end to end: Alice (a full [TestDevice]) encrypts envelopes
/// exactly as production does; the inbox runs on Bob's device and must
/// decrypt, create conversations, persist messages, and maintain unread
/// counters. The SignalR transport is replaced by a plain StreamController
/// pushing the same payload shape the hub delivers
/// ({senderId, encryptedBody, groupId?}).
void main() {
  late TestDevice alice;
  late TestDevice bob;
  late StreamController<Map<String, dynamic>> transport;
  late MessageInboxService inbox;

  setUp(() async {
    alice = await TestDevice.create('alice');
    bob = await TestDevice.create('bob');
    transport = StreamController<Map<String, dynamic>>.broadcast();
    inbox = MessageInboxService(
      database: bob.db,
      sessionManager: bob.sessions,
      incomingMessages: transport.stream,
    );
    inbox.start();

    // Alice has a live session towards Bob, as after a key-bundle fetch.
    await alice.sessions.initiateSession(bob.id, await bob.keyBundle());
  });

  tearDown(() async {
    await inbox.dispose();
    await transport.close();
    await alice.close();
    await bob.close();
  });

  /// Encrypts [text] on Alice's side and returns the hub payload Bob's
  /// inbox would receive for it.
  Future<Map<String, dynamic>> alicePayload(String text,
      {String? groupId}) async {
    final envelope = await alice.sessions.encryptMessage(bob.id, text);
    return {
      'senderId': alice.id,
      'encryptedBody': base64Encode(utf8.encode(envelope)),
      'groupId': ?groupId,
    };
  }

  /// Pushes a payload through the fake transport and waits until the inbox
  /// has fully persisted it.
  Future<Message> deliver(Map<String, dynamic> payload) {
    final persisted = inbox.persistedMessages.first;
    transport.add(payload);
    return persisted;
  }

  test('decrypts and persists a message with no chat screen involved',
      () async {
    final message = await deliver(await alicePayload('hello'));

    expect(message.body, equals('hello'));
    expect(message.senderId, equals(alice.id));
    expect(message.conversationId, equals(alice.id));
    expect(message.status, equals('delivered'));

    // The row really is in Bob's database, not just on the stream.
    final stored = await bob.db.select(bob.db.messages).get();
    expect(stored, hasLength(1));
    expect(stored.single.body, equals('hello'));
  });

  test('creates the direct conversation on first message from a stranger',
      () async {
    await deliver(await alicePayload('hi, you do not know me'));

    final conversations = await bob.db.select(bob.db.conversations).get();
    expect(conversations, hasLength(1));
    expect(conversations.single.id, equals(alice.id));
    expect(conversations.single.type, equals('direct'));
    expect(conversations.single.lastMessageAt, isNotNull);
  });

  test('increments unread count per message', () async {
    await deliver(await alicePayload('one'));
    await deliver(await alicePayload('two'));

    final conversation = await (bob.db.select(bob.db.conversations)
          ..where((c) => c.id.equals(alice.id)))
        .getSingle();
    expect(conversation.unreadCount, equals(2));
  });

  test('group message lands in the group conversation', () async {
    final message = await deliver(await alicePayload('hi all', groupId: 'g1'));

    expect(message.conversationId, equals('g1'));
    final conversation = await (bob.db.select(bob.db.conversations)
          ..where((c) => c.id.equals('g1')))
        .getSingle();
    expect(conversation.type, equals('group'));
  });

  test('undecryptable payload is preserved with the [encrypted] marker',
      () async {
    final message = await deliver({
      'senderId': alice.id,
      'encryptedBody': base64Encode(utf8.encode('garbage, not an envelope')),
    });

    // Nothing is silently dropped: the raw body is kept and marked so the
    // UI can show "message could not be decrypted".
    expect(message.body, startsWith('[encrypted] '));
  });

  test('malformed payload does not kill the subscription', () async {
    // No senderId → handler returns early; a later valid message must
    // still be processed (the subscription survived).
    transport.add({'encryptedBody': 'whatever'});

    final message = await deliver(await alicePayload('still alive'));
    expect(message.body, equals('still alive'));
  });
}
