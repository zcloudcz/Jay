import 'package:calltype/core/network/api_client.dart';
import 'package:calltype/core/storage/database.dart';
import 'package:calltype/core/storage/secure_storage.dart';
import 'package:calltype/features/organization/mfa_section.dart';
import 'package:calltype/features/settings/account_screen.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../helpers/localized_app.dart';

/// Answers GET /accounts/{id}/mfa (the only call MfaSection makes on load)
/// and records every request path.
class _FakeAdapter implements HttpClientAdapter {
  final paths = <String>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    paths.add(options.path);
    return ResponseBody.fromString(
      options.path == '/accounts/login'
          ? '{"accountId":"6f9619ff-8b86-d011-b42d-00cf4fc964aa"}'
          : '{"enabled":false,"confirmedAt":null,"backupCodesRemaining":0}',
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }
}

void main() {
  const accountId = '6f9619ff-8b86-d011-b42d-00cf4fc964aa';

  Future<_FakeAdapter> pumpScreen(
    WidgetTester tester, {
    AppDatabase? db,
    bool linkFirstPlatform = false,
  }) async {
    final adapter = _FakeAdapter();
    final api = ApiClient(
      baseUrl: 'https://example.test',
      dio: Dio()..httpClientAdapter = adapter,
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<ApiClient>.value(value: api),
          Provider.value(value: SecureStorage()),
          if (db != null) Provider<AppDatabase>.value(value: db),
        ],
        child: localizedApp(
          home: AccountScreen(linkFirstPlatform: linkFirstPlatform),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return adapter;
  }

  testWidgets('registered account: MFA section, explainer and a copyable id', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({'ct_account_id': accountId});
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final adapter = await pumpScreen(tester);

    expect(find.byType(MfaSection), findsOneWidget);
    expect(find.text(l10nEn.mfaSectionTitle), findsOneWidget);
    expect(find.text(l10nEn.mfaEnableButton), findsOneWidget);
    expect(find.text(l10nEn.accountMfaExplainer), findsOneWidget);
    expect(adapter.paths, contains('/accounts/$accountId/mfa'));

    expect(find.text(l10nEn.accountInfoTitle), findsOneWidget);
    expect(find.text(accountId), findsOneWidget);
    await tester.tap(find.byTooltip(l10nEn.accountIdCopy));
    await tester.pumpAndSettle();
    expect(copied, [accountId]);
    expect(find.text(l10nEn.accountIdCopied), findsOneWidget);
  });

  testWidgets('unregistered device: neither the MFA section nor an id', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final adapter = await pumpScreen(tester);

    expect(find.byType(MfaSection), findsNothing);
    expect(find.text(l10nEn.accountMfaExplainer), findsNothing);
    expect(find.text(l10nEn.accountInfoTitle), findsNothing);
    expect(find.byTooltip(l10nEn.accountIdCopy), findsNothing);
    expect(
      adapter.paths,
      isEmpty,
      reason: 'no MFA status call without an account',
    );
    // The register form is still there.
    expect(find.text(l10nEn.accountEmailLabel), findsOneWidget);
  });

  group('link UX A4: after a login without chats', () {
    Future<void> logIn(WidgetTester tester) async {
      await tester.ensureVisible(find.text(l10nEn.accountSwitchToLogin));
      await tester.tap(find.text(l10nEn.accountSwitchToLogin));
      await tester.pump();
      await tester.enterText(
        find.widgetWithText(TextFormField, l10nEn.accountEmailLabel),
        'me@example.test',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, l10nEn.accountPassphraseLabel),
        'correct horse',
      );
      final submit = find.widgetWithText(
        FilledButton,
        l10nEn.accountLoginTitle,
      );
      await tester.ensureVisible(submit);
      await tester.pump();
      await tester.tap(submit);
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    late AppDatabase db;
    setUp(() {
      FlutterSecureStorage.setMockInitialValues({'ct_device_id': 'device-1'});
      db = AppDatabase.forTesting(NativeDatabase.memory());
    });
    tearDown(() => db.close());

    testWidgets('web: explains why and offers the link screen', (tester) async {
      await pumpScreen(tester, db: db, linkFirstPlatform: true);
      await logIn(tester);

      expect(find.text(l10nEn.accountLinked), findsOneWidget);
      expect(find.text(l10nEn.accountNoChatsTitle), findsOneWidget);
      expect(find.text(l10nEn.accountNoChatsBody), findsOneWidget);
      expect(find.text(l10nEn.accountNoChatsAction), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('web with chats: no explanation', (tester) async {
      await tester.runAsync(
        () => db
            .into(db.conversations)
            .insert(ConversationsCompanion.insert(id: 'c1', type: 'direct')),
      );
      await pumpScreen(tester, db: db, linkFirstPlatform: true);
      await logIn(tester);

      expect(find.text(l10nEn.accountLinked), findsOneWidget);
      expect(find.text(l10nEn.accountNoChatsTitle), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('phone: no explanation (the phone is where chats live)', (
      tester,
    ) async {
      await pumpScreen(tester, db: db);
      await logIn(tester);

      expect(find.text(l10nEn.accountLinked), findsOneWidget);
      expect(find.text(l10nEn.accountNoChatsTitle), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
