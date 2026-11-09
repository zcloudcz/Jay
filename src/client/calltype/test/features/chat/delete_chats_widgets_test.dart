import 'dart:typed_data';

import 'package:calltype/core/network/signalr_client.dart';
import 'package:calltype/features/channels/channels_controller.dart';
import 'package:calltype/features/chat/chat_controller.dart';
import 'package:calltype/features/chat/chat_delete_dialogs.dart';
import 'package:calltype/features/chat/chat_deletion.dart';
import 'package:calltype/features/chat/chat_screen.dart';
import 'package:calltype/features/chat/message_inbox_service.dart';
import 'package:calltype/features/chat_list/chat_list_controller.dart';
import 'package:calltype/features/chat_list/chat_list_screen.dart';
import 'package:calltype/features/contacts/contacts_controller.dart';
import 'package:calltype/features/contacts/contacts_screen.dart';
import 'package:calltype/features/devices/device_service.dart';
import 'package:calltype_core/crypto/key_manager.dart';
import 'package:calltype_core/crypto/session_manager.dart';
import 'package:calltype_core/devices/device_directory.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:calltype_core/storage/drift_protocol_store.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../helpers/localized_app.dart';
import '../../helpers/test_device.dart';

/// Menus and dialogs of spec 2026-11-09-delete-chats-contacts (D1, D3 to
/// D7) on narrow and wide layouts. The service and controllers are fakes
/// that record calls; the database side is covered by
/// delete_chats_flow_test.dart.
const _bob = 'b0000000-0000-4000-8000-000000000001';
const _group = 'd0000000-0000-4000-8000-000000000004';
const _business = 'e0000000-0000-4000-8000-000000000005';
const _bot = 'f0000000-0000-4000-8000-000000000006';

class _Deletion extends ChatDeletionService {
  _Deletion(AppDatabase db)
    : super(database: db, sender: null, directory: () => null);
  final deleted = <String>[];
  final left = <String>[];
  LeaveGroupResult leaveResult = LeaveGroupResult.left;

  @override
  Future<bool> deleteChat(String conversationId) async {
    deleted.add(conversationId);
    return false;
  }

  @override
  Future<LeaveGroupResult> leaveGroup(String groupId) async {
    left.add(groupId);
    return leaveResult;
  }
}

class _Chats extends ChatListController {
  _Chats(AppDatabase db, this.rows) : super(database: db);
  final List<Conversation> rows;
  @override
  List<Conversation> get conversations => rows;
  @override
  Future<void> loadConversations() async {}
}

class _Contacts extends ContactsController {
  _Contacts(AppDatabase db, this.rows) : super(database: db);
  final List<Contact> rows;
  final removed = <String>[];
  @override
  List<Contact> get contacts => rows;
  @override
  Future<void> loadContacts() async {}
  @override
  Future<void> deleteContact(String deviceId) async => removed.add(deviceId);
}

Contact _contact(String id, String handle, {bool bot = false}) => Contact(
  deviceId: id,
  userHandle: handle,
  identityKey: Uint8List(0),
  verified: false,
  addedAt: DateTime(2026),
  isBot: bot,
  nameChangedAt: 0,
);

void main() {
  late AppDatabase db;
  late _Deletion deletion;
  late _Chats chats;
  late _Contacts contacts;
  late SignalRClient signal;
  late DeviceService devices;
  late ChannelsController channels;

  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    db = AppDatabase.forTesting(NativeDatabase.memory());
    deletion = _Deletion(db);
    chats = _Chats(db, [
      const Conversation(id: _bob, type: 'direct', unreadCount: 0),
      const Conversation(
        id: _group,
        type: 'group',
        title: 'Hiking',
        unreadCount: 0,
      ),
      const Conversation(
        id: _business,
        type: 'group',
        title: 'Acme deal',
        unreadCount: 0,
        organizationId: 'org-1',
        organizationName: 'Acme',
      ),
      const Conversation(id: _bot, type: 'direct', unreadCount: 0),
    ]);
    contacts = _Contacts(db, [
      _contact(_bob, 'CT-BOB0-0001'),
      // The removed test bot: still a contact, its identity is gone.
      _contact(_bot, 'CT-BOT0-0001', bot: true),
    ]);
    signal = SignalRClient(baseUrl: 'http://unused', deviceId: 'me');
    // The bottom bar reads the channel unread count.
    channels = ChannelsController(
      database: db,
      apiClient: ApiClient(baseUrl: 'http://unused'),
      channelPosts: const Stream.empty(),
      channelDeleted: const Stream.empty(),
      joinChannels: () async {},
      leaveChannel: (_) async {},
    );
    final keys = KeyManager(secureStorage: InMemorySecureStorage());
    devices = DeviceService(
      database: db,
      apiClient: NoDeviceListsApi(),
      keyManager: keys,
      sessionManager: SessionManager(
        store: DriftProtocolStore(db),
        keyManager: keys,
      ),
      signalRClient: signal,
    );
  });

  Future<void> pumpList(WidgetTester tester, {required bool wide}) async {
    tester.view.physicalSize = wide
        ? const Size(1200, 900)
        : const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider.value(value: db),
          Provider<ChatDeletionService?>.value(value: deletion),
          ChangeNotifierProvider<SignalRClient>.value(value: signal),
          ChangeNotifierProvider<DeviceService>.value(value: devices),
          ChangeNotifierProvider<ChatListController>.value(value: chats),
          ChangeNotifierProvider<ContactsController>.value(value: contacts),
          ChangeNotifierProvider<ChannelsController>.value(value: channels),
        ],
        child: localizedApp(home: const ChatListScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> cleanUp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    chats.dispose();
    contacts.dispose();
    devices.dispose();
    channels.dispose();
    signal.dispose();
    await tester.runAsync(db.close);
  }

  testWidgets('phone: long press on a 1:1 chat deletes it after the '
      'confirmation that says the other side keeps its copy', (tester) async {
    await pumpList(tester, wide: false);
    await tester.longPress(find.text('CT-BOB0-0001'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chat-action-leave')), findsNothing);
    expect(
      find.byKey(const ValueKey('chat-action-delete-contact')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('chat-action-delete')));
    await tester.pumpAndSettle();

    expect(find.text(l10nEn.chatDeleteChatTitle), findsOneWidget);
    expect(find.text(l10nEn.chatDeleteChatBody), findsOneWidget);
    expect(find.byKey(const ValueKey('delete-chat-leave')), findsNothing);
    expect(
      find.byKey(const ValueKey('delete-chat-business-note')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('delete-chat-confirm')));
    await tester.pumpAndSettle();
    expect(deletion.deleted, [_bob]);
    expect(find.text(l10nEn.chatDeleted), findsOneWidget);
    await cleanUp(tester);
  });

  testWidgets('phone: swiping a row asks first; cancel deletes nothing', (
    tester,
  ) async {
    await pumpList(tester, wide: false);
    expect(find.byType(Dismissible), findsNWidgets(4));
    await tester.drag(find.text('Hiking'), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('delete-chat-dialog')), findsOneWidget);
    expect(find.text(l10nEn.chatDeleteGroupChatBody), findsOneWidget);
    await tester.tap(find.text(l10nEn.commonCancel));
    await tester.pumpAndSettle();
    expect(deletion.deleted, isEmpty);
    expect(find.text('Hiking'), findsOneWidget, reason: 'the row stays');
    await cleanUp(tester);
  });

  testWidgets('a group offers "Leave group and delete" in the delete dialog', (
    tester,
  ) async {
    await pumpList(tester, wide: false);
    await tester.longPress(find.text('Hiking'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chat-action-leave')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('chat-action-delete-contact')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('chat-action-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('delete-chat-leave')));
    await tester.pumpAndSettle();
    expect(deletion.left, [_group]);
    expect(deletion.deleted, isEmpty, reason: 'leaveGroup deletes itself');
    await cleanUp(tester);
  });

  testWidgets('the last admin gets a clear message instead of leaving', (
    tester,
  ) async {
    deletion.leaveResult = LeaveGroupResult.lastAdmin;
    await pumpList(tester, wide: false);
    await tester.longPress(find.text('Hiking'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-action-leave')));
    await tester.pumpAndSettle();
    expect(find.text(l10nEn.chatLeaveGroupBody), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('leave-group-confirm')));
    await tester.pumpAndSettle();
    expect(deletion.left, [_group]);
    expect(find.text(l10nEn.chatLeaveGroupLastAdmin), findsOneWidget);
    await cleanUp(tester);
  });

  testWidgets('a business chat says the archive is not affected', (
    tester,
  ) async {
    await pumpList(tester, wide: false);
    await tester.longPress(find.text('Acme deal'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-action-delete')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('delete-chat-business-note')),
      findsOneWidget,
    );
    expect(find.text(l10nEn.chatDeleteBusinessNote), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('delete-chat-confirm')));
    await tester.pumpAndSettle();
    expect(deletion.deleted, [_business]);
    await cleanUp(tester);
  });

  testWidgets('wide layout: an overflow button per row, no swipe; the chat '
      'with a removed bot is deletable like any other', (tester) async {
    await pumpList(tester, wide: true);
    expect(find.byType(Dismissible), findsNothing);
    await tester.tap(find.byKey(const ValueKey('chat-row-menu-$_bot')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-action-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('delete-chat-confirm')));
    await tester.pumpAndSettle();
    expect(deletion.deleted, [_bot]);
    await cleanUp(tester);
  });

  testWidgets('delete contact from the chat list: chat too by default', (
    tester,
  ) async {
    await pumpList(tester, wide: false);
    await tester.longPress(find.text('CT-BOB0-0001'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-action-delete-contact')));
    await tester.pumpAndSettle();
    expect(find.text(l10nEn.contactDeleteBody('CT-BOB0-0001')), findsOneWidget);
    final box = tester.widget<CheckboxListTile>(
      find.byKey(const ValueKey('delete-contact-also-chat')),
    );
    expect(box.value, isTrue);
    await tester.tap(find.byKey(const ValueKey('delete-contact-confirm')));
    await tester.pumpAndSettle();
    expect(contacts.removed, [_bob]);
    expect(deletion.deleted, [_bob]);
    expect(find.text(l10nEn.contactDeleted), findsOneWidget);
    await cleanUp(tester);
  });

  testWidgets('delete contact from the contact list, keeping the chat', (
    tester,
  ) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<ChatDeletionService?>.value(value: deletion),
          ChangeNotifierProvider<ChatListController>.value(value: chats),
          ChangeNotifierProvider<ContactsController>.value(value: contacts),
        ],
        child: localizedApp(home: const ContactsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuButton<void>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('contact-delete-$_bob')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('delete-contact-also-chat')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('delete-contact-confirm')));
    await tester.pumpAndSettle();
    expect(contacts.removed, [_bob]);
    expect(deletion.deleted, isEmpty);
    await cleanUp(tester);
  });

  /// The chat screen on a router, so a deletion can leave it.
  Future<ChatController> pumpChat(WidgetTester tester, String id) async {
    final keys = KeyManager(secureStorage: InMemorySecureStorage());
    final sessions = SessionManager(
      store: DriftProtocolStore(db),
      keyManager: keys,
    );
    final directory = DeviceDirectory(
      database: db,
      apiClient: NoDeviceListsApi(),
      selfDeviceId: 'me',
      selfSigningKey: () async =>
          (await keys.getSignedIdentityBundle())['signingKey']!,
      selfIdentityKey: keys.getPublicIdentityKey,
    );
    late ChatController chat;
    await tester.runAsync(() async {
      chat = ChatController(
        database: db,
        signalRClient: signal,
        sessionManager: sessions,
        inbox: MessageInboxService(
          database: db,
          sessionManager: sessions,
          directory: () => directory,
          incomingMessages: const Stream.empty(),
        ),
        apiClient: ApiClient(baseUrl: 'http://unused'),
        conversationId: id,
        directory: directory,
      );
    });
    final router = GoRouter(
      initialLocation: '/chats/$id',
      routes: [
        GoRoute(
          path: '/chats',
          builder: (_, _) => const Text('chat list'),
          routes: [
            GoRoute(
              path: ':id',
              builder: (_, state) =>
                  ChatScreen(contactId: state.pathParameters['id']!),
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider.value(value: db),
          Provider<ChatDeletionService?>.value(value: deletion),
          ChangeNotifierProvider<SignalRClient>.value(value: signal),
          ChangeNotifierProvider<ChatListController>.value(value: chats),
          ChangeNotifierProvider<ContactsController>.value(value: contacts),
          ChangeNotifierProvider<ChatController>.value(value: chat),
        ],
        child: localizedApp(router: router),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    return chat;
  }

  Future<void> closeChat(WidgetTester tester, ChatController chat) async {
    await tester.pumpWidget(const SizedBox());
    chat.dispose();
    await tester.pump(const Duration(seconds: 1));
    await cleanUp(tester);
  }

  testWidgets('1:1 chat menu: delete chat goes back to the list; delete '
      'contact is offered for a contact', (tester) async {
    final chat = await pumpChat(tester, _bob);
    await tester.tap(find.byKey(const ValueKey('chat-direct-menu')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chat-delete-contact')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chat-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('delete-chat-confirm')));
    await tester.pumpAndSettle();
    expect(deletion.deleted, [_bob]);
    expect(find.text('chat list'), findsOneWidget);
    await closeChat(tester, chat);
  });

  testWidgets('group chat menu: leave group, then back to the list', (
    tester,
  ) async {
    final chat = await pumpChat(tester, _group);
    await tester.tap(find.byKey(const ValueKey('chat-group-menu')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chat-delete')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chat-leave-group')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('leave-group-confirm')));
    await tester.pumpAndSettle();
    expect(deletion.left, [_group]);
    expect(find.text('chat list'), findsOneWidget);
    await closeChat(tester, chat);
  });

  testWidgets('without the deletion service the dialogs do nothing', (
    tester,
  ) async {
    late BuildContext captured;
    await tester.pumpWidget(
      localizedApp(
        home: Builder(
          builder: (context) {
            captured = context;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(
      await confirmDeleteChat(
        captured,
        conversationId: _bob,
        group: false,
        business: false,
      ),
      isFalse,
    );
    await cleanUp(tester);
  });
}
