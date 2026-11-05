import 'package:calltype/core/network/api_client.dart';
import 'package:calltype/core/storage/database.dart';
import 'package:calltype/features/chat/chat_controller.dart';
import 'package:calltype/features/chat_list/chat_list_controller.dart';
import 'package:calltype/features/contacts/bot_link.dart';
import 'package:calltype/features/contacts/contacts_controller.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../helpers/localized_app.dart';

const _botId = 'b0000000-0000-4000-8000-000000000001';

/// `GET /devices/by-handle/{handle}` answering with the bot's public profile.
class _Api extends ApiClient {
  _Api() : super(baseUrl: 'http://unused');
  final lookups = <String>[];
  @override
  Future<Map<String, dynamic>> findDeviceByHandle(String handle) async {
    lookups.add(handle);
    return {
      'deviceId': _botId,
      'userHandle': 'CT-AB12-CD34',
      'isBot': true,
      'displayName': 'Hermes',
    };
  }
}

/// The bot deep link flow (contract section 8): add with confirmation or
/// open, then the chat with `/start <payload>` in the composer, never sent.
void main() {
  late AppDatabase db;
  late _Api api;
  late ContactsController contacts;
  late ChatListController chats;

  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    db = AppDatabase.forTesting(NativeDatabase.memory());
    api = _Api();
    contacts = ContactsController(database: db, apiClient: api);
    chats = ChatListController(database: db);
  });

  /// Lets real database work and the fake clock advance together.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  Future<void> pumpLink(WidgetTester tester, String link) async {
    final router = GoRouter(
      initialLocation: botLinkRoute(parseBotLink(link)!),
      routes: [
        GoRoute(path: '/chats', builder: (_, _) => const Text('chat list')),
        GoRoute(
          path: '/chats/:id',
          builder: (_, state) => Text(
            'chat ${state.pathParameters['id']} draft '
            '${(state.extra as ComposerDraft?)?.text}',
          ),
        ),
        GoRoute(
          path: '/bot/:handle',
          builder: (_, state) => BotLinkScreen(
            link: parseBotLink(
              'calltype://bot/${state.pathParameters['handle']}'
              '?${state.uri.query}',
            )!,
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: contacts),
          ChangeNotifierProvider.value(value: chats),
        ],
        child: localizedApp(router: router),
      ),
    );
    await settle(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(db.close);
    });
  }

  testWidgets('a new bot needs confirmation, then the chat opens pre-filled', (
    tester,
  ) async {
    await pumpLink(tester, 'calltype://bot/CT-AB12-CD34?start=ref_42');
    // The existing add-contact preview, with the bot badge and notice.
    expect(find.text(l10nEn.contactsConfirmAddTitle), findsOneWidget);
    expect(find.text(l10nEn.botNotice), findsOneWidget);
    expect(await tester.runAsync(() => db.select(db.contacts).get()), isEmpty);
    await tester.tap(find.text(l10nEn.commonAdd));
    await settle(tester);
    expect(find.text('chat $_botId draft /start ref_42'), findsOneWidget);
    final saved = (await tester.runAsync(() => db.select(db.contacts).get()))!;
    expect(saved.single.isBot, isTrue);
    // Nothing was sent: no message row exists.
    expect(await tester.runAsync(() => db.select(db.messages).get()), isEmpty);
  });

  testWidgets('declining adds nothing and returns to the chat list', (
    tester,
  ) async {
    await pumpLink(tester, 'calltype://bot/CT-AB12-CD34?start=ref_42');
    await tester.tap(find.text(l10nEn.commonCancel));
    await settle(tester);
    expect(find.text('chat list'), findsOneWidget);
    expect(await tester.runAsync(() => db.select(db.contacts).get()), isEmpty);
  });

  testWidgets('a known bot opens directly; an invalid payload becomes /start', (
    tester,
  ) async {
    await tester.runAsync(
      () => db
          .into(db.contacts)
          .insert(
            ContactsCompanion.insert(
              deviceId: _botId,
              userHandle: 'CT-AB12-CD34',
              identityKey: Uint8List(0),
              addedAt: DateTime(2026),
              isBot: const Value(true),
            ),
          ),
    );
    await pumpLink(tester, 'calltype://bot/ct-ab12-cd34?start=bad%20payload');
    expect(find.text(l10nEn.contactsConfirmAddTitle), findsNothing);
    expect(find.text('chat $_botId draft /start'), findsOneWidget);
    expect(api.lookups, isEmpty);
  });
}
