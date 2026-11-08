import 'package:calltype/core/network/signalr_client.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:calltype/features/chat/chat_controller.dart';
import 'package:calltype/features/chat/chat_screen.dart';
import 'package:calltype/features/chat/message_inbox_service.dart';
import 'package:calltype/features/chat_list/chat_list_controller.dart';
import 'package:calltype/features/contacts/contacts_controller.dart';
import 'package:calltype_core/devices/device_directory.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../helpers/fake_multi_device_server.dart';
import '../../helpers/localized_app.dart';
import '../../helpers/test_device.dart';

const _phoneId = 'a0000000-0000-4000-8000-000000000001';
const _webId = 'a0000000-0000-4000-8000-000000000002';
const _bobId = 'b0000000-0000-4000-8000-000000000001';

/// A hub that rejects every send the way an organization policy does.
class _RejectingHub extends FakeHubClient {
  _RejectingHub(super.server, super.deviceId);

  @override
  Future<void> sendDirectFanout(
    String recipientIdentityId,
    Map<String, String> encryptedPayloads, {
    required String messageId,
  }) async => throw StateError('business_conversation_required');
}

void main() {
  /// Pumps the chat of the phone (or of its linked web device) with Bob,
  /// sends one message the hub rejects and returns after the snackbar frame.
  Future<void> rejectedSend(WidgetTester tester, {required bool companion}) async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final server = FakeMultiDeviceServer();
    final phone = (await tester.runAsync(() => TestDevice.create(_phoneId)))!;
    final web = (await tester.runAsync(() => TestDevice.create(_webId)))!;
    final bob = (await tester.runAsync(() => TestDevice.create(_bobId)))!;
    for (final d in [phone, web, bob]) {
      server.add(d);
    }
    final alice = companion ? web : phone;
    final hub = _RejectingHub(server, alice.id);
    // Created inside runAsync: its internal locks must live in the real zone.
    late DeviceDirectory directory;
    late ChatController chat;
    await tester.runAsync(() async {
      directory = server.directoryFor(alice);
      await alice.db.into(alice.db.conversations).insert(
        ConversationsCompanion.insert(id: bob.id, type: 'direct'),
      );
      if (companion) {
        await server.link(phone, [web], version: 1);
        await directory.refresh(_phoneId, ensurePinned: server.pinFor(web));
      }
      chat = ChatController(
        database: alice.db,
        signalRClient: hub,
        sessionManager: alice.sessions,
        inbox: MessageInboxService(
          database: alice.db,
          sessionManager: alice.sessions,
          directory: () => directory,
          incomingMessages: const Stream.empty(),
        ),
        apiClient: FakeDeviceApi(server),
        conversationId: bob.id,
        directory: directory,
      );
      await chat.sendMessage('hey');
    });
    expect(chat.isCompanion, companion);
    // Built after the awaited DB work: their drift watch streams use
    // fake-clock timers that would otherwise stall the transactions above.
    final contacts = ContactsController(database: alice.db);
    final chats = ChatListController(database: alice.db);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider.value(value: alice.db),
          ChangeNotifierProvider<SignalRClient>.value(value: hub),
          ChangeNotifierProvider.value(value: contacts),
          ChangeNotifierProvider.value(value: chats),
          ChangeNotifierProvider.value(value: chat),
        ],
        child: localizedApp(home: ChatScreen(contactId: bob.id)),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    await tester.pump();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      chat.dispose();
      chats.dispose();
      contacts.dispose();
      hub.dispose();
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(() async {
        await server.close();
        for (final d in [phone, web, bob]) {
          await d.close();
        }
      });
    });
  }

  testWidgets('a primary is offered the business chat after the rejection', (
    tester,
  ) async {
    await rejectedSend(tester, companion: false);
    expect(find.text(l10nEn.hubErrorBusinessConversationRequired), findsOneWidget);
    expect(
      find.text(l10nEn.hubErrorBusinessConversationRequiredAction),
      findsOneWidget,
    );
  });

  testWidgets('a companion only gets the explanation, no business chat action', (
    tester,
  ) async {
    await rejectedSend(tester, companion: true);
    expect(find.text(l10nEn.hubErrorBusinessConversationRequired), findsOneWidget);
    expect(
      find.text(l10nEn.hubErrorBusinessConversationRequiredAction),
      findsNothing,
    );
  });
}
