import 'dart:typed_data';

import 'package:calltype_core/crypto/key_manager.dart';
import 'package:calltype_core/crypto/session_manager.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype/core/network/signalr_client.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:calltype/features/chat/chat_controller.dart';
import 'package:calltype/features/chat/chat_screen.dart';
import 'package:calltype/features/chat/message_inbox_service.dart';
import 'package:calltype/features/chat_list/chat_list_controller.dart';
import 'package:calltype/features/contacts/contacts_controller.dart';
import 'package:calltype/features/contacts/contacts_screen.dart';
import 'package:calltype/shared/widgets/bot_badge.dart';
import 'package:calltype_core/devices/device_directory.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../helpers/localized_app.dart';
import '../../helpers/test_device.dart';

const _botId = '11111111-2222-3333-4444-555555555555';
const _primaryId = '99999999-0000-4000-8000-000000000001';

class LookupApi extends ApiClient {
  LookupApi({required this.isBot}) : super(baseUrl: 'http://unused');
  final bool isBot;
  @override
  Future<Map<String, dynamic>> findDeviceByHandle(String handle) async => {
    'deviceId': _botId,
    'userHandle': handle,
    'isBot': isBot,
  };
}

void main() {
  // Windows variant: the screen offers the paste dialog instead of a camera.
  testWidgets(
    'add-contact preview shows the BOT badge and notice BEFORE confirming',
    (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final controller = ContactsController(
        database: db,
        apiClient: LookupApi(isBot: true),
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<ContactsController>.value(
          value: controller,
          child: localizedApp(home: const ContactsScreen()),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('Add by handle'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'CT-HERM-ES01');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(find.text('Add this contact?'), findsOneWidget);
      expect(find.byType(BotBadge), findsOneWidget);
      expect(find.text(l10nEn.botNotice), findsOneWidget);
      // Nothing is saved until the user confirms.
      final saved = await tester.runAsync(() => db.select(db.contacts).get());
      expect(saved, isEmpty);

      await tester.tap(find.text('Add'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      final contact = await tester.runAsync(
        () => db.select(db.contacts).getSingle(),
      );
      expect(contact!.isBot, isTrue);

      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await tester.runAsync(db.close);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('a human contact gets no badge in the preview', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final controller = ContactsController(
      database: db,
      apiClient: LookupApi(isBot: false),
    );
    final preview = await controller.resolveContact('CT-ALIC-E001');
    expect(preview.isBot, isFalse);
    controller.dispose();
    await tester.runAsync(db.close);
  });

  /// Returns the teardown: widgets first, then controllers (cancelling their
  /// drift watch streams), then the fake-clock timers drift uses for stream
  /// teardown, and only then the database — any other order hangs close().
  Future<Future<void> Function()> pumpChat(
    WidgetTester tester, {
    required bool isBot,
    bool companion = false,
    bool deviceChange = false,
  }) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final signal = SignalRClient(baseUrl: 'http://unused', deviceId: 'me');
    final keys = KeyManager(secureStorage: InMemorySecureStorage());
    final sessions = SessionManager(database: db, keyManager: keys);
    final directory = DeviceDirectory(
      database: db,
      apiClient: NoDeviceListsApi(),
      selfDeviceId: 'me',
      selfSigningKey: () async =>
          (await keys.getSignedIdentityBundle())['signingKey']!,
      selfIdentityKey: keys.getPublicIdentityKey,
    );
    final contacts = ContactsController(database: db);
    final chats = ChatListController(database: db);
    late ChatController chat;
    await tester.runAsync(() async {
      await db
          .into(db.contacts)
          .insert(
            ContactsCompanion.insert(
              deviceId: _botId,
              userHandle: 'CT-HERM-ES01',
              identityKey: Uint8List(0),
              addedAt: DateTime.now(),
              isBot: Value(isBot),
            ),
          );
      await contacts.loadContacts();
      if (companion) {
        // What a verified list leaves on a linked device: 'me' belongs to
        // the identity _primaryId.
        await db
            .into(db.knownDeviceListMembers)
            .insert(
              KnownDeviceListMembersCompanion.insert(
                deviceId: 'me',
                primaryDeviceId: _primaryId,
              ),
            );
        await directory.load();
      }
      if (deviceChange) {
        await db
            .into(db.messages)
            .insert(
              MessagesCompanion.insert(
                id: 'device-change',
                conversationId: _botId,
                senderId: _botId,
                body: const Value('added'),
                type: const Value('device-change'),
                status: const Value('delivered'),
                createdAt: DateTime.now(),
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
          directory: () => directory,
          incomingMessages: const Stream.empty(),
        ),
        apiClient: ApiClient(baseUrl: 'http://unused'),
        conversationId: _botId,
        directory: directory,
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
        child: localizedApp(home: const ChatScreen(contactId: _botId)),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    return () async {
      await tester.pumpWidget(const SizedBox());
      chat.dispose();
      chats.dispose();
      contacts.dispose();
      signal.dispose();
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(db.close);
    };
  }

  testWidgets('chat with a bot: badge, one-time notice, NO call buttons', (
    tester,
  ) async {
    final cleanUp = await pumpChat(tester, isBot: true);
    expect(find.byType(BotBadge), findsOneWidget);
    expect(find.byTooltip('Voice call'), findsNothing);
    expect(find.byTooltip('Video call'), findsNothing);
    expect(find.text(l10nEn.botNotice), findsOneWidget);

    // Dismissing is remembered — the notice is one-time per bot.
    await tester.tap(find.text('Got it'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(find.text(l10nEn.botNotice), findsNothing);
    final db = tester.element(find.byType(ChatScreen)).read<AppDatabase>();
    final seen = await tester.runAsync(() => db.select(db.backupState).get());
    expect(seen!.single.key, 'bot_notice_seen:$_botId');
    await cleanUp();
  });

  testWidgets('chat with a person keeps the call buttons and shows no badge', (
    tester,
  ) async {
    final cleanUp = await pumpChat(tester, isBot: false);
    expect(find.byType(BotBadge), findsNothing);
    expect(find.byTooltip('Voice call'), findsOneWidget);
    expect(find.byTooltip('Video call'), findsOneWidget);
    expect(find.text(l10nEn.botNotice), findsNothing);
    await cleanUp();
  });

  testWidgets('on a companion the call buttons are hidden', (tester) async {
    final cleanUp = await pumpChat(tester, isBot: false, companion: true);
    expect(find.byTooltip('Voice call'), findsNothing);
    expect(find.byTooltip('Video call'), findsNothing);
    await cleanUp();
  });

  testWidgets('a device change is a system line, not a bubble', (tester) async {
    final cleanUp = await pumpChat(tester, isBot: false, deviceChange: true);
    expect(find.text(l10nEn.chatDeviceAdded), findsOneWidget);
    expect(find.text('added'), findsNothing);
    await cleanUp();
  });
}
