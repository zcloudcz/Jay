import 'package:calltype/features/privacy/block_controller.dart';
import 'package:calltype/features/privacy/chat_safety.dart';
import 'package:calltype/features/privacy/legal_links.dart';
import 'package:calltype/features/privacy/user_safety_actions.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/network/user_safety_api.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../helpers/localized_app.dart';
import '../settings/account_deletion_test.dart' show FakeServer, apiWith;

/// The fake server answers on real async gaps (runAsync): pump until no
/// request is in flight, instead of a fixed delay that a loaded runner
/// outlasts.
Future<void> settleRequests(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
    await tester.pumpAndSettle();
  }
}

/// Spec 2026-11-14-go-live A5-A9: legal links, the consent line, block /
/// unblock from the 1:1 menu with the banner, and the report dialog.
void main() {
  group('legal links (D14, A5, A6)', () {
    late List<Uri> opened;
    setUp(() {
      opened = [];
      legalUrlLauncher = (uri) async {
        opened.add(uri);
        return true;
      };
    });

    test('Czech UI gets the Czech page, every other language English', () {
      expect(
        legalUrl(LegalPage.privacy, 'cs'),
        'https://jay.zcloud.cz/legal/privacy-cs.html',
      );
      expect(
        legalUrl(LegalPage.deleteAccount, 'de'),
        'https://jay.zcloud.cz/legal/delete-account-en.html',
      );
    });

    for (final (locale, suffix) in [('en', 'en'), ('cs', 'cs')]) {
      testWidgets('consent line opens the $suffix terms and privacy', (
        tester,
      ) async {
        await tester.pumpWidget(
          localizedApp(
            locale: Locale(locale),
            home: const Scaffold(body: Center(child: LegalConsentLine())),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('legal-consent-terms')));
        await tester.tap(find.byKey(const ValueKey('legal-consent-privacy')));
        await tester.pump();
        expect(opened.map((u) => u.path), [
          '/legal/terms-$suffix.html',
          '/legal/privacy-$suffix.html',
        ]);
      });
    }

    testWidgets('a failed launch shows the address', (tester) async {
      legalUrlLauncher = (_) async => false;
      await tester.pumpWidget(
        localizedApp(
          home: const Scaffold(body: LegalPageTile(page: LegalPage.support)),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('legal-support')));
      await tester.pump();
      expect(
        find.textContaining('https://jay.zcloud.cz/legal/support-en.html'),
        findsOneWidget,
      );
    });
  });

  group('block and report (A7-A9)', () {
    late AppDatabase db;
    late FakeServer server;
    late ApiClient api;
    late BlockController blocks;
    const peer = 'aaaaaaaa-0000-0000-0000-000000000001';

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      server = FakeServer({
        'POST /users/$peer/report': (
          200,
          {'reportId': 42, 'createdAt': '2026-11-14T10:00:00Z'},
        ),
        // An old-style server answer keeps the local cache as the truth.
        'GET /blocks': (404, null),
      });
      api = apiWith(server);
      blocks = BlockController(database: db, apiClient: api);
    });

    tearDown(() async {
      blocks.dispose();
      await db.close();
    });

    Widget app(Widget Function(BuildContext) body) => MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: api),
        Provider<AppDatabase>.value(value: db),
        ChangeNotifierProvider<BlockController?>.value(value: blocks),
        ChangeNotifierProvider<BlockController>.value(value: blocks),
      ],
      child: localizedApp(
        home: Scaffold(body: Builder(builder: body)),
      ),
    );

    testWidgets('1:1 menu blocks after confirmation and shows the banner', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(
          app(
            (context) => Column(
              children: [
                const BlockedChatBanner(peerId: peer, name: 'Eve'),
                PopupMenuButton<void>(
                  key: const ValueKey('menu'),
                  itemBuilder: (context) =>
                      directChatSafetyItems(context, peerId: peer, name: 'Eve'),
                ),
              ],
            ),
          ),
        );
        expect(find.byKey(const ValueKey('blocked-chat-banner')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('menu')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('chat-block-user')));
        await tester.pumpAndSettle();
        expect(find.text(l10nEn.userBlockConfirmTitle('Eve')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('user-block-confirm')));
        await tester.pumpAndSettle();
        await settleRequests(tester);
        expect(server.calls, contains('PUT /blocks/$peer'));
        expect(blocks.isBlocked(peer), isTrue);
        expect(
          find.byKey(const ValueKey('blocked-chat-banner')),
          findsOneWidget,
        );

        // The menu now offers Unblock.
        await tester.tap(find.byKey(const ValueKey('menu')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('chat-unblock-user')), findsOneWidget);
      });
    });

    testWidgets('a report from a message attaches its text by default', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(
          app(
            (context) => TextButton(
              onPressed: () => showReportUserDialog(
                context,
                deviceId: peer,
                name: 'Eve',
                evidence: const [ReportEvidence(text: 'you will regret it')],
                attachByDefault: true,
              ),
              child: const Text('go'),
            ),
          ),
        );
        await tester.tap(find.text('go'));
        await tester.pumpAndSettle();
        expect(find.text(l10nEn.userReportAttach(1)), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('user-report-reason')),
          'threats',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('user-report-submit')));
        await tester.pumpAndSettle();
        await settleRequests(tester);
        final request = server.requests.singleWhere(
          (r) => r.path == '/users/$peer/report',
        );
        final body = request.data as Map;
        expect(body['category'], 'terms');
        expect(body['reason'], 'threats');
        expect((body['messages'] as List).single['text'], 'you will regret it');
        expect(find.text(l10nEn.userReportReceipt('42')), findsOneWidget);
      });
    });

    testWidgets('unticking the attachment sends no message text', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(
          app(
            (context) => TextButton(
              onPressed: () => showReportUserDialog(
                context,
                deviceId: peer,
                name: 'Eve',
                evidence: const [ReportEvidence(text: 'private')],
                attachByDefault: true,
              ),
              child: const Text('go'),
            ),
          ),
        );
        await tester.tap(find.text('go'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('user-report-attach')));
        await tester.enterText(
          find.byKey(const Key('user-report-reason')),
          'spam',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('user-report-submit')));
        await tester.pumpAndSettle();
        await settleRequests(tester);
        final body =
            server.requests
                    .singleWhere((r) => r.path == '/users/$peer/report')
                    .data
                as Map;
        expect(body['messages'] ?? const [], isEmpty);
      });
    });
  });
}
