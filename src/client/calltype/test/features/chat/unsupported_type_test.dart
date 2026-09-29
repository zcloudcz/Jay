import 'dart:typed_data';

import 'package:calltype/core/crypto/key_manager.dart';
import 'package:calltype/core/crypto/session_manager.dart';
import 'package:calltype/core/network/api_client.dart';
import 'package:calltype/core/network/signalr_client.dart';
import 'package:calltype/core/storage/database.dart';
import 'package:calltype/features/chat/chat_controller.dart';
import 'package:calltype/features/chat/chat_screen.dart';
import 'package:calltype/features/chat/message_bubble.dart';
import 'package:calltype/features/chat/message_inbox_service.dart';
import 'package:calltype/features/chat_list/chat_list_controller.dart';
import 'package:calltype/features/contacts/contacts_controller.dart';
import 'package:calltype_core/devices/device_directory.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../helpers/localized_app.dart';
import '../../helpers/test_device.dart';

const _peer = 'peer-device';

/// K1: a stored message of a type this version cannot render shows the
/// localized placeholder, never its raw JSON body. D §4.1: a message from
/// another of MY devices renders as mine.
void main() {
  testWidgets('unknown and media rows show the placeholder; own-device rows '
      'are mine', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final signal = SignalRClient(baseUrl: 'http://unused', deviceId: 'me');
    final sessions = SessionManager(
      database: db,
      keyManager: KeyManager(secureStorage: InMemorySecureStorage()),
    );
    final contacts = ContactsController(database: db);
    final chats = ChatListController(database: db);
    late ChatController chat;
    await tester.runAsync(() async {
      await db
          .into(db.contacts)
          .insert(
            ContactsCompanion.insert(
              deviceId: _peer,
              userHandle: 'CT-PEER-0001',
              identityKey: Uint8List(0),
              addedAt: DateTime.now(),
            ),
          );
      await db
          .into(db.conversations)
          .insert(ConversationsCompanion.insert(id: _peer, type: 'direct'));
      // My other (linked) device, as stream D will record it.
      await db
          .into(db.contactDevices)
          .insert(
            ContactDevicesCompanion.insert(
              deviceId: 'my-laptop',
              contactId: selfContactId,
              addedAt: DateTime.now(),
            ),
          );
      final t = DateTime.utc(2026, 9, 29, 10);
      for (final (id, type, body, sender, offset) in [
        ('m1', 'media', '{"v":1,"kind":"image"}', _peer, 0),
        ('m2', 'poll', '{"q":"?"}', _peer, 1),
        ('m3', 'text', 'plain hello', _peer, 2),
        ('m4', 'text', 'from my laptop', 'my-laptop', 3),
      ]) {
        await db
            .into(db.messages)
            .insert(
              MessagesCompanion.insert(
                id: id,
                conversationId: _peer,
                senderId: sender,
                body: Value(body),
                type: Value(type),
                createdAt: t.add(Duration(minutes: offset)),
              ),
            );
      }
      chat = ChatController(
        database: db,
        signalRClient: signal,
        sessionManager: sessions,
        inbox: MessageInboxService(
          database: db,
          sessionManager: sessions,
          incomingMessages: const Stream.empty(),
        ),
        apiClient: ApiClient(baseUrl: 'http://unused'),
        conversationId: _peer,
        myDeviceId: 'me',
      );
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider.value(value: db),
          ChangeNotifierProvider.value(value: signal),
          ChangeNotifierProvider.value(value: contacts),
          ChangeNotifierProvider.value(value: chats),
          ChangeNotifierProvider.value(value: chat),
        ],
        child: localizedApp(home: const ChatScreen(contactId: _peer)),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    expect(find.text(l10nEn.msgUnsupportedType), findsNWidgets(2));
    expect(find.textContaining('"kind"'), findsNothing);
    expect(find.textContaining('"q"'), findsNothing);
    expect(find.text('plain hello'), findsOneWidget);

    MessageBubble bubble(String text) =>
        tester.widget<MessageBubble>(
          find.ancestor(
            of: find.text(text),
            matching: find.byType(MessageBubble),
          ),
        );
    expect(bubble('from my laptop').isMine, isTrue);
    expect(bubble('plain hello').isMine, isFalse);

    await tester.pumpWidget(const SizedBox());
    chat.dispose();
    chats.dispose();
    contacts.dispose();
    signal.dispose();
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(db.close);
  });
}
