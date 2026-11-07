import 'package:calltype/core/network/api_client.dart';
import 'package:calltype/core/network/signalr_client.dart';
import 'package:calltype/core/storage/database.dart';
import 'package:calltype/features/chat/bot_commands.dart';
import 'package:calltype/features/chat/chat_controller.dart';
import 'package:calltype/features/chat/chat_screen.dart';
import 'package:calltype/features/chat/mentions.dart';
import 'package:calltype/features/chat/message_bubble.dart';
import 'package:calltype/features/chat/message_inbox_service.dart';
import 'package:calltype/features/chat/message_input.dart';
import 'package:calltype/features/chat_list/chat_list_controller.dart';
import 'package:calltype/features/contacts/contacts_controller.dart';
import 'package:calltype_core/messaging/agent_payload.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../helpers/localized_app.dart';
import '../../helpers/test_device.dart';

/// Agent messaging widgets (contract section 8): mention ids from the
/// composer, the "/" menu, the pre-filled draft, the "edited" label and
/// bot buttons (only under a received bot message).

const _hermes = MentionCandidate(
  label: 'Boss bot',
  token: 'Hermes',
  detail: 'CT-AAAA-BBBB',
  isBot: true,
  id: 'b0000000-0000-4000-8000-000000000001',
);

Widget _input({
  List<MentionCandidate> candidates = const [_hermes],
  Future<void> Function(String, List<String>)? onSendWithMentions,
  Future<void> Function(String)? onSend,
  Future<List<CommandSuggestion>> Function()? commands,
  String? initialText,
}) => localizedApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.bottomCenter,
      child: MessageInput(
        onSend: onSend ?? (_) async {},
        onSendWithMentions: onSendWithMentions,
        mentionCandidates: candidates,
        commandSuggestions: commands,
        initialText: initialText,
      ),
    ),
  ),
);

class _Transport extends SignalRClient {
  _Transport() : super(baseUrl: 'http://unused', deviceId: 'alice');
  final sent = <Map<String, String>>[];
  @override
  Future<void> sendDirectFanout(
    String recipientIdentityId,
    Map<String, String> encryptedPayloads, {
    required String messageId,
  }) async => sent.add(Map.of(encryptedPayloads));
}

class _Api extends ApiClient {
  _Api(this.peers) : super(baseUrl: 'http://unused');
  final List<TestDevice> peers;
  @override
  Future<Map<String, dynamic>> getKeyBundle(String id) =>
      peers.firstWhere((p) => p.id == id).keyBundle();
}

void main() {
  group('composer', () {
    testWidgets('a picked mention is sent as its identity id', (tester) async {
      final sent = <(String, List<String>)>[];
      await tester.pumpWidget(
        _input(onSendWithMentions: (t, m) async => sent.add((t, m))),
      );
      await tester.enterText(find.byType(TextField), '@he');
      await tester.pump();
      await tester.tap(find.text('Boss bot'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '@Hermes deploy');
      await tester.pump();
      await tester.tap(find.byTooltip(l10nEn.chatInputSend));
      await tester.pump();
      expect(sent.single.$1, '@Hermes deploy');
      expect(sent.single.$2, ['b0000000-0000-4000-8000-000000000001']);
    });

    testWidgets('a mention deleted after picking is not sent', (tester) async {
      final sent = <List<String>>[];
      await tester.pumpWidget(
        _input(onSendWithMentions: (t, m) async => sent.add(m)),
      );
      await tester.enterText(find.byType(TextField), '@he');
      await tester.pump();
      await tester.tap(find.text('Boss bot'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'never mind');
      await tester.pump();
      await tester.tap(find.byTooltip(l10nEn.chatInputSend));
      await tester.pump();
      expect(sent.single, isEmpty);
    });

    testWidgets('"/" opens the command menu; a group pick inserts '
        '/cmd@HANDLE', (tester) async {
      var loads = 0;
      await tester.pumpWidget(
        _input(
          commands: () async {
            loads++;
            return const [
              CommandSuggestion(
                command: 'help',
                description: 'Show help',
                insert: '/help@CT-AAAA-BBBB ',
                botName: 'Hermes',
              ),
              CommandSuggestion(
                command: 'new',
                description: 'New chat',
                insert: '/new@CT-AAAA-BBBB ',
                botName: 'Hermes',
              ),
            ];
          },
        ),
      );
      await tester.enterText(find.byType(TextField), '/');
      await tester.pump();
      await tester.pump();
      expect(find.text('/help'), findsOneWidget);
      expect(find.text('/new'), findsOneWidget);
      expect(
        find.text(l10nEn.chatCommandFromBot('Show help', 'Hermes')),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextField), '/he');
      await tester.pump();
      expect(find.text('/new'), findsNothing);
      await tester.tap(find.text('/help'));
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, '/help@CT-AAAA-BBBB ');
      expect(find.text('/help'), findsNothing);
      expect(loads, 1);
    });

    testWidgets('no bot in the chat: "/" shows nothing', (tester) async {
      await tester.pumpWidget(_input());
      await tester.enterText(find.byType(TextField), '/');
      await tester.pump();
      expect(find.byType(ListTile), findsNothing);
    });

    testWidgets('a slash later in the text never opens the menu', (
      tester,
    ) async {
      await tester.pumpWidget(
        _input(
          commands: () async => const [
            CommandSuggestion(
              command: 'help',
              description: 'Show help',
              insert: '/help ',
            ),
          ],
        ),
      );
      await tester.enterText(find.byType(TextField), 'and/or');
      await tester.pump();
      await tester.pump();
      expect(find.text('/help'), findsNothing);
    });

    testWidgets('initialText is pre-filled and NOT sent', (tester) async {
      final sent = <String>[];
      await tester.pumpWidget(
        _input(initialText: '/start ref42', onSend: (t) async => sent.add(t)),
      );
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, '/start ref42');
      expect(sent, isEmpty);
      await tester.tap(find.byTooltip(l10nEn.chatInputSend));
      await tester.pump();
      expect(sent, ['/start ref42']);
    });
  });

  group('bubble', () {
    Widget bubble({
      bool edited = false,
      List<MessageButton> buttons = const [],
      void Function(MessageButton)? onButton,
      bool deleted = false,
    }) => localizedApp(
      home: Scaffold(
        body: MessageBubble(
          text: 'hello',
          time: '12:00',
          isMine: false,
          edited: edited,
          buttons: buttons,
          onButton: onButton,
          deleted: deleted,
        ),
      ),
    );

    testWidgets('edited label only on edited messages', (tester) async {
      await tester.pumpWidget(bubble(edited: true));
      expect(find.text(l10nEn.chatMessageEdited), findsOneWidget);
      await tester.pumpWidget(bubble());
      expect(find.text(l10nEn.chatMessageEdited), findsNothing);
      await tester.pumpWidget(bubble(edited: true, deleted: true));
      expect(find.text(l10nEn.chatMessageEdited), findsNothing);
    });

    testWidgets('buttons render and report the tapped one', (tester) async {
      final tapped = <MessageButton>[];
      await tester.pumpWidget(
        bubble(
          buttons: const [
            MessageButton(id: 'yes', label: 'Approve once'),
            MessageButton(id: 'no', label: 'Deny'),
          ],
          onButton: tapped.add,
        ),
      );
      await tester.tap(find.text('Deny'));
      expect(tapped, const [MessageButton(id: 'no', label: 'Deny')]);
    });
  });

  group('chat screen', () {
    /// Alice's chat with [peer]; [isBot] marks the contact. One received
    /// message with buttons, one own message.
    Future<({ChatController chat, _Transport hub, TestDevice alice})> pumpChat(
      WidgetTester tester, {
      required bool isBot,
    }) async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      final alice = (await tester.runAsync(() => TestDevice.create('alice')))!;
      final peer = (await tester.runAsync(() => TestDevice.create('peer')))!;
      final hub = _Transport();
      late ChatController chat;
      final contacts = ContactsController(database: alice.db);
      await tester.runAsync(() async {
        final db = alice.db;
        await db
            .into(db.conversations)
            .insert(ConversationsCompanion.insert(id: 'peer', type: 'direct'));
        await db
            .into(db.contacts)
            .insert(
              ContactsCompanion.insert(
                deviceId: 'peer',
                userHandle: 'CT-PEER-0001',
                identityKey: Uint8List(0),
                addedAt: DateTime(2026),
                isBot: Value(isBot),
              ),
            );
        await db
            .into(db.messages)
            .insert(
              MessagesCompanion.insert(
                id: 'bot-msg',
                conversationId: 'peer',
                senderId: 'peer',
                body: const Value('Approve the command?'),
                status: const Value('delivered'),
                createdAt: DateTime(2026, 1, 1, 10),
                actionsJson: Value(
                  encodeActionsJson(const [
                    MessageButton(
                      id: 'approve:r:q:once',
                      label: 'Approve once',
                    ),
                  ]),
                ),
                editedAt: Value(DateTime(2026, 1, 1, 10, 1)),
              ),
            );
        await db
            .into(db.messages)
            .insert(
              MessagesCompanion.insert(
                id: 'mine',
                conversationId: 'peer',
                senderId: 'alice',
                body: const Value('my text'),
                status: const Value('sent'),
                createdAt: DateTime(2026, 1, 1, 9),
              ),
            );
        await contacts.loadContacts();
        chat = ChatController(
          database: db,
          signalRClient: hub,
          sessionManager: alice.sessions,
          inbox: MessageInboxService(
            database: db,
            sessionManager: alice.sessions,
            directory: () => alice.directory,
            incomingMessages: const Stream.empty(),
          ),
          apiClient: _Api([peer]),
          conversationId: 'peer',
          directory: alice.directory,
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
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
          child: localizedApp(home: const ChatScreen(contactId: 'peer')),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        chat.dispose();
        chats.dispose();
        contacts.dispose();
        hub.dispose();
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(() async {
          await alice.close();
          await peer.close();
        });
      });
      return (chat: chat, hub: hub, alice: alice);
    }

    testWidgets('a bot message shows its buttons and the edited label; a tap '
        'sends the press', (tester) async {
      final r = await pumpChat(tester, isBot: true);
      expect(find.text('Approve the command?'), findsOneWidget);
      expect(find.text(l10nEn.chatMessageEdited), findsOneWidget);
      expect(
        find.widgetWithText(OutlinedButton, 'Approve once'),
        findsOneWidget,
      );
      // Hook check only: the send itself is covered in agent_messaging_test
      // (real DB work cannot run inside the widget test's fake zone).
      final bubble = tester
          .widgetList<MessageBubble>(find.byType(MessageBubble))
          .firstWhere((b) => b.text == 'Approve the command?');
      expect(bubble.onButton, isNotNull);
      expect(bubble.buttons, const [
        MessageButton(id: 'approve:r:q:once', label: 'Approve once'),
      ]);
      expect(r.hub.sent, isEmpty);
    });

    testWidgets(
      'tapping a bot button sends the press',
      (tester) async {
        final r = await pumpChat(tester, isBot: true);
        await tester.tap(find.widgetWithText(OutlinedButton, 'Approve once'));
        // The send runs real database work: let it advance on both clocks.
        for (var i = 0; i < 30 && r.hub.sent.isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(r.hub.sent, hasLength(1));
        final rows = await tester.runAsync(
          () => (r.alice.db.select(
            r.alice.db.messages,
          )..where((m) => m.body.equals('Approve once'))).get(),
        );
        expect(rows!.single.replyToId, 'bot-msg');
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    testWidgets('an own sent text offers Edit, a received one does not', (
      tester,
    ) async {
      await pumpChat(tester, isBot: true);
      await tester.longPress(find.text('my text'));
      await tester.pumpAndSettle();
      expect(find.text(l10nEn.chatMessageEdit), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Approve the command?'));
      await tester.pumpAndSettle();
      expect(find.text(l10nEn.chatMessageReply), findsOneWidget);
      expect(find.text(l10nEn.chatMessageEdit), findsNothing);
    });

    testWidgets('the same message from a human shows no buttons', (
      tester,
    ) async {
      await pumpChat(tester, isBot: false);
      expect(find.text('Approve the command?'), findsOneWidget);
      expect(find.text('Approve once'), findsNothing);
    });
  });
}
