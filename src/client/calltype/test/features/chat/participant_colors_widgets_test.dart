import 'package:calltype/app/theme.dart';
import 'package:calltype/core/network/signalr_client.dart';
import 'package:calltype/features/chat/chat_controller.dart';
import 'package:calltype/features/chat/chat_screen.dart';
import 'package:calltype/features/chat/message_bubble.dart';
import 'package:calltype/features/chat/message_inbox_service.dart';
import 'package:calltype/features/chat/participant_colors.dart';
import 'package:calltype/features/chat_list/chat_list_controller.dart';
import 'package:calltype/features/contacts/contacts_controller.dart';
import 'package:calltype/features/contacts/contacts_screen.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../helpers/localized_app.dart';
import '../../helpers/test_device.dart';

/// Group chat colors (spec 2026-11-09-participant-colors): colored label and
/// outline for other members, nothing for me, nothing in 1:1 chats, and the
/// picker from the label, the message menu and the contacts screen.

const _bob = 'b0000000-0000-4000-8000-0000000000b0';
const _carol = 'c0000000-0000-4000-8000-0000000000c0';
const _bobHandle = 'CT-BOB0-0001';
const _carolHandle = 'CT-CARO-0001';

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'http://unused');
  @override
  Future<List<GroupMemberInfo>> getGroupMemberInfos(String groupId) async => [
    const GroupMemberInfo(deviceId: 'alice', userHandle: 'CT-ALIC-0001'),
    const GroupMemberInfo(
      deviceId: _bob,
      userHandle: _bobHandle,
      displayName: 'Bob',
    ),
    const GroupMemberInfo(
      deviceId: _carol,
      userHandle: _carolHandle,
      displayName: 'Carol',
    ),
  ];
}

Color _light(String key) =>
    participantPalette[defaultParticipantColorIndex(key)].light;

MessageBubble _bubble(WidgetTester tester, String text) => tester
    .widgetList<MessageBubble>(find.byType(MessageBubble))
    .firstWhere((b) => b.text == text);

/// The name above message [id] (the tappable label).
Text _label(WidgetTester tester, String id) => tester.widget<Text>(
  find.descendant(
    of: find.byKey(ValueKey('participant-label:$id')),
    matching: find.byType(Text),
  ),
);

/// Alice's chat [conversationId] (a group with Bob and Carol, or a direct
/// chat with Bob) with one message each; Carol quotes Bob, Alice quotes
/// Carol.
Future<void> pumpChat(
  WidgetTester tester, {
  required bool group,
  ParticipantColors? colors,
  ThemeData? theme,
}) async {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final conversationId = group ? 'g1' : _bob;
  final alice = (await tester.runAsync(() => TestDevice.create('alice')))!;
  final hub = SignalRClient(baseUrl: 'http://unused', deviceId: 'alice');
  late ChatController chat;
  final contacts = ContactsController(database: alice.db);
  await tester.runAsync(() async {
    final db = alice.db;
    await db
        .into(db.conversations)
        .insert(
          ConversationsCompanion.insert(
            id: conversationId,
            type: group ? 'group' : 'direct',
            title: Value(group ? 'Team' : null),
          ),
        );
    await db
        .into(db.contacts)
        .insert(
          ContactsCompanion.insert(
            deviceId: _bob,
            userHandle: _bobHandle,
            identityKey: Uint8List(0),
            addedAt: DateTime(2026),
          ),
        );
    Future<void> message(
      String id,
      String sender,
      String body,
      int minute, {
      String? replyTo,
      String? replySender,
      String? replyPreview,
    }) => db
        .into(db.messages)
        .insert(
          MessagesCompanion.insert(
            id: id,
            conversationId: conversationId,
            senderId: sender,
            body: Value(body),
            status: const Value('delivered'),
            createdAt: DateTime(2026, 1, 1, 10, minute),
            replyToId: Value(replyTo),
            replySenderId: Value(replySender),
            replyPreview: Value(replyPreview),
          ),
        );
    await message('m1', _bob, 'hello from bob', 1);
    if (group) {
      await message(
        'm2',
        _carol,
        'hello from carol',
        2,
        replyTo: 'm1',
        replySender: _bob,
        replyPreview: 'hello from bob',
      );
    }
    await message(
      'm3',
      'alice',
      'my text',
      3,
      replyTo: group ? 'm2' : 'm1',
      replySender: group ? _carol : _bob,
      replyPreview: 'quoted',
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
      apiClient: _Api(),
      conversationId: conversationId,
      directory: alice.directory,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  final chats = ChatListController(database: alice.db);
  await tester.runAsync(chats.loadConversations);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider.value(value: alice.db),
        ChangeNotifierProvider<SignalRClient>.value(value: hub),
        ChangeNotifierProvider.value(value: contacts),
        ChangeNotifierProvider.value(value: chats),
        ChangeNotifierProvider.value(value: chat),
        if (colors != null) ChangeNotifierProvider.value(value: colors),
      ],
      child: localizedApp(
        home: ChatScreen(contactId: conversationId),
        theme: theme,
      ),
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
    await tester.runAsync(alice.close);
  });
}

void main() {
  testWidgets('a group colors other members, never me', (tester) async {
    final colors = ParticipantColors();
    addTearDown(colors.dispose);
    await pumpChat(tester, group: true, colors: colors);

    final bob = _light(_bobHandle);
    final carol = _light(_carolHandle);
    expect(bob, isNot(carol));
    expect(_label(tester, 'm1').style?.color, bob);
    expect(_label(tester, 'm1').style?.fontWeight, FontWeight.w600);
    expect(_label(tester, 'm2').style?.color, carol);
    expect(_bubble(tester, 'hello from bob').outlineColor, bob);
    expect(_bubble(tester, 'hello from carol').outlineColor, carol);
    // Carol quotes Bob: Bob's color; my reply quotes Carol: Carol's color.
    expect(_bubble(tester, 'hello from carol').quoteAccent, bob);
    expect(_bubble(tester, 'my text').outlineColor, isNull);
    expect(_bubble(tester, 'my text').quoteAccent, carol);
  });

  testWidgets('without the app-wide store the defaults still show', (
    tester,
  ) async {
    await pumpChat(tester, group: true);
    expect(_bubble(tester, 'hello from bob').outlineColor, _light(_bobHandle));
    expect(find.byKey(const ValueKey('participant-label:m1')), findsNothing);
  });

  testWidgets('a 1:1 chat is unchanged', (tester) async {
    final colors = ParticipantColors();
    addTearDown(colors.dispose);
    await pumpChat(tester, group: false, colors: colors);
    expect(_bubble(tester, 'hello from bob').outlineColor, isNull);
    expect(_bubble(tester, 'my text').quoteAccent, isNull);
    await tester.longPress(find.text('hello from bob'));
    await tester.pumpAndSettle();
    expect(find.text(l10nEn.participantColorAction), findsNothing);
  });

  testWidgets('the dark theme uses the dark tones', (tester) async {
    final colors = ParticipantColors();
    addTearDown(colors.dispose);
    await pumpChat(tester, group: true, colors: colors, theme: AppTheme.dark);
    final bob = participantPalette[defaultParticipantColorIndex(_bobHandle)];
    expect(_bubble(tester, 'hello from bob').outlineColor, bob.dark);
    expect(_label(tester, 'm1').style?.color, bob.dark);
  });

  testWidgets('a tap on the name picks a color; Automatic from the menu '
      'restores the default', (tester) async {
    final colors = ParticipantColors();
    addTearDown(colors.dispose);
    await pumpChat(tester, group: true, colors: colors);
    final initial = defaultParticipantColorIndex(_bobHandle);
    final other = (initial + 1) % participantPalette.length;

    await tester.tap(find.byKey(const ValueKey('participant-label:m1')));
    await tester.pumpAndSettle();
    expect(find.text(l10nEn.participantColorTitle('Bob')), findsOneWidget);
    expect(find.text(l10nEn.participantColorAutomatic), findsOneWidget);
    for (var i = 0; i < participantPalette.length; i++) {
      expect(find.byTooltip(participantColorName(l10nEn, i)), findsOneWidget);
    }
    await tester.tap(find.byTooltip(participantColorName(l10nEn, other)));
    await tester.pumpAndSettle();
    expect(colors.chosenIndex(_bobHandle), other);
    expect(
      _bubble(tester, 'hello from bob').outlineColor,
      participantPalette[other].light,
    );
    expect(_label(tester, 'm1').style?.color, participantPalette[other].light);
    // Carol is untouched; Bob's color follows him into Carol's quote.
    expect(
      _bubble(tester, 'hello from carol').outlineColor,
      _light(_carolHandle),
    );
    expect(
      _bubble(tester, 'hello from carol').quoteAccent,
      participantPalette[other].light,
    );

    // The quote in Carol's bubble repeats the text: the last match is Bob's.
    await tester.longPress(find.text('hello from bob').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10nEn.participantColorAction));
    await tester.pumpAndSettle();
    // The current choice is marked as selected for screen readers.
    expect(
      tester.getSemantics(find.byKey(ValueKey('participant-color-$other'))),
      isSemantics(
        isSelected: true,
        isButton: true,
        label: participantColorName(l10nEn, other),
      ),
    );
    await tester.tap(find.text(l10nEn.participantColorAutomatic));
    await tester.pumpAndSettle();
    expect(colors.chosenIndex(_bobHandle), isNull);
    expect(_bubble(tester, 'hello from bob').outlineColor, _light(_bobHandle));
  });

  testWidgets('my own message has no color action', (tester) async {
    final colors = ParticipantColors();
    addTearDown(colors.dispose);
    await pumpChat(tester, group: true, colors: colors);
    await tester.longPress(find.text('my text'));
    await tester.pumpAndSettle();
    expect(find.text(l10nEn.chatMessageReply), findsOneWidget);
    expect(find.text(l10nEn.participantColorAction), findsNothing);
  });

  testWidgets('the contacts menu opens the same picker by handle', (
    tester,
  ) async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final contacts = ContactsController(database: db);
    final colors = ParticipantColors();
    await tester.runAsync(() async {
      await db
          .into(db.contacts)
          .insert(
            ContactsCompanion.insert(
              deviceId: _bob,
              userHandle: _bobHandle,
              displayName: const Value('Bobby'),
              identityKey: Uint8List(0),
              addedAt: DateTime(2026),
            ),
          );
      await contacts.loadContacts();
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ContactsController>.value(value: contacts),
          ChangeNotifierProvider.value(value: colors),
        ],
        child: localizedApp(home: const ContactsScreen()),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    await tester.tap(find.byType(PopupMenuButton<void>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10nEn.participantColorContactAction));
    await tester.pumpAndSettle();
    expect(find.text(l10nEn.participantColorTitle('Bobby')), findsOneWidget);
    await tester.tap(find.byTooltip(participantColorName(l10nEn, 0)));
    await tester.pumpAndSettle();
    // The same key the group chat uses for Bob (D3).
    expect(colors.chosenIndex(_bobHandle), 0);

    await tester.pumpWidget(const SizedBox());
    contacts.dispose();
    colors.dispose();
    await tester.runAsync(db.close);
  });
}
