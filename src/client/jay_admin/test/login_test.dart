import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'helpers/fake_backend.dart';

Future<void> fillLogin(WidgetTester tester, {String code = '123456'}) async {
  await tester.enterText(find.byKey(const Key('login-email')), ' op@zcloud.cz ');
  await tester.enterText(find.byKey(const Key('login-passphrase')), 'correct horse');
  await tester.enterText(find.byKey(const Key('login-code')), code);
  await tester.tap(find.byKey(const Key('login-submit')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('signed out: any route redirects to the login form', (tester) async {
    await pumpAdmin(tester, loggedIn: false, location: '/queue?status=open');
    expect(find.text('Operator sign-in'), findsOneWidget);
    expect(find.byKey(const Key('login-banner')), findsNothing);
  });

  testWidgets('sends email, SHA-256 authKey and TOTP code, then lands on the requested route', (tester) async {
    final h = await pumpAdmin(tester, loggedIn: false, location: '/channels');
    await fillLogin(tester);

    final sent = jsonDecode(h.backend.where('POST', '/admin/session').single.body) as Map;
    expect(sent['email'], 'op@zcloud.cz');
    // Same derivation as the app's account_screen.dart.
    expect(sent['authKey'], sha256.convert(utf8.encode('correct horse')).toString());
    expect(sent['authKey'], matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(sent['code'], '123456');
    expect(sent.containsKey('backupCode'), isFalse);
    expect(h.session.isLoggedIn, isTrue);
    expect(find.byKey(const Key('channels-query')), findsOneWidget);
  });

  testWidgets('backup code toggle sends backupCode instead of code', (tester) async {
    final h = await pumpAdmin(tester, loggedIn: false);
    await tester.tap(find.byKey(const Key('login-toggle-backup')));
    await tester.pump();
    expect(find.text('Backup code'), findsOneWidget);
    await fillLogin(tester, code: 'ABCD-EFGH');
    final sent = jsonDecode(h.backend.where('POST', '/admin/session').single.body) as Map;
    expect(sent['backupCode'], 'ABCD-EFGH');
    expect(sent.containsKey('code'), isFalse);
  });

  testWidgets('empty fields are rejected locally without a request', (tester) async {
    final h = await pumpAdmin(tester, loggedIn: false);
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pumpAndSettle();
    expect(find.text('Enter the e-mail.'), findsOneWidget);
    expect(find.text('Enter the passphrase.'), findsOneWidget);
    expect(find.text('Enter the code.'), findsOneWidget);
    expect(h.backend.requests, isEmpty);
  });

  final cases = <(int, String?, String)>[
    (401, 'invalid_credentials', 'Wrong e-mail or passphrase.'),
    (403, 'not_an_operator', 'This account is not an operator.'),
    (403, 'mfa_not_enabled', 'Two-factor authentication is not enabled'),
    (401, 'mfa_invalid_code', 'The code is wrong or has expired.'),
    (429, 'mfa_locked', 'Too many wrong codes.'),
    (429, null, 'Too many attempts.'),
  ];
  for (final (status, code, text) in cases) {
    testWidgets('login error $status ${code ?? '(no code)'} shows a clear message', (tester) async {
      final backend = FakeBackend()
        ..sessionResponse = code == null
            ? http.Response('', status)
            : FakeBackend.error(status, code);
      final h = await pumpAdmin(tester, backend: backend, loggedIn: false);
      await fillLogin(tester);
      expect(find.byKey(const Key('login-error')), findsOneWidget);
      expect(find.textContaining(text), findsOneWidget);
      expect(h.session.isLoggedIn, isFalse);
      // The single-use code field is cleared for the retry.
      expect(tester.widget<TextField>(find.descendant(of: find.byKey(const Key('login-code')), matching: find.byType(TextField))).controller!.text, isEmpty);
    });
  }

  testWidgets('Czech locale shows Czech login texts and errors', (tester) async {
    final backend = FakeBackend()..sessionResponse = FakeBackend.error(403, 'not_an_operator');
    await pumpAdmin(tester, backend: backend, loggedIn: false, locale: const Locale('cs'));
    expect(find.text('Přihlášení provozovatele'), findsOneWidget);
    await fillLogin(tester);
    expect(find.textContaining('Tento účet není provozovatel.'), findsOneWidget);
  });
}
