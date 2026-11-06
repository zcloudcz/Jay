import 'package:calltype/core/network/api_client.dart';
import 'package:calltype/core/storage/secure_storage.dart';
import 'package:calltype/features/organization/mfa_section.dart';
import 'package:calltype/features/settings/account_screen.dart';
import 'package:dio/dio.dart';
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
      '{"enabled":false,"confirmedAt":null,"backupCodesRemaining":0}',
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }
}

void main() {
  const accountId = '6f9619ff-8b86-d011-b42d-00cf4fc964aa';

  Future<_FakeAdapter> pumpScreen(WidgetTester tester) async {
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
        ],
        child: localizedApp(home: const AccountScreen()),
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
}
