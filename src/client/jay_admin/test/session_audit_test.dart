import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:jay_admin/api/admin_api.dart';
import 'package:jay_admin/app.dart';
import 'package:jay_admin/config.dart';
import 'package:jay_admin/session.dart';

import 'helpers/fake_backend.dart';

void main() {
  testWidgets('a 401 mid-session returns to the login, re-login restores the route', (tester) async {
    final backend = FakeBackend();
    final h = await pumpAdmin(tester, backend: backend, location: '/queue?status=open&category=spam');
    expect(find.text('Ad Blaster'), findsOneWidget);

    // Token revoked or expired server-side: the next call answers 401.
    backend.rejectToken = true;
    await tester.tap(find.byKey(const Key('tab-resolved')));
    await tester.pumpAndSettle();

    expect(h.session.isLoggedIn, isFalse);
    expect(h.api.hasToken, isFalse);
    expect(find.text('Operator sign-in'), findsOneWidget);
    expect(find.text('The server ended your session. Sign in again to continue where you were.'), findsOneWidget);
    expect(currentLocation(tester), startsWith('/login?from='));

    backend.rejectToken = false;
    await tester.enterText(find.byKey(const Key('login-email')), 'op@zcloud.cz');
    await tester.enterText(find.byKey(const Key('login-passphrase')), 'pass');
    await tester.enterText(find.byKey(const Key('login-code')), '654321');
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/queue?status=resolved&category=spam');
    expect(backend.requests.last.headers['Authorization'], 'Bearer op-token');
  });

  testWidgets('countdown shows remaining time and expiry logs out locally', (tester) async {
    var now = DateTime.now();
    final h = await pumpAdmin(tester, location: '/audit', clock: () => now);
    expect(find.textContaining(RegExp(r'^Session (29:5\d|30:00)$')), findsOneWidget);

    now = now.add(const Duration(minutes: 26));
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining(RegExp(r'^Session [34]:\d\d$')), findsOneWidget);

    now = now.add(const Duration(minutes: 5));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(h.session.isLoggedIn, isFalse);
    expect(find.text('Your session expired. Sign in again to continue where you were.'), findsOneWidget);
    expect(currentLocation(tester), '/login?from=%2Faudit');
  });

  testWidgets('logout drops the token and shows the login', (tester) async {
    final h = await pumpAdmin(tester);
    await tester.tap(find.byKey(const Key('logout')));
    await tester.pumpAndSettle();
    expect(h.api.hasToken, isFalse);
    expect(find.text('You have been logged out.'), findsOneWidget);
  });

  testWidgets('audit log lists decisions and the CSV export triggers a download', (tester) async {
    final h = await pumpAdmin(tester, location: '/audit');
    expect(find.byKey(const Key('audit-table')), findsOneWidget);
    expect(find.text('Remove post'), findsOneWidget);
    expect(find.text('rule K4 Fraud and deception'), findsOneWidget);
    expect(find.text(operatorId), findsOneWidget);

    await tester.tap(find.byKey(const Key('export-csv')));
    await tester.pumpAndSettle();
    final csvReq = h.backend.requests.where((r) => r.url.queryParameters['format'] == 'csv').single;
    expect(csvReq.headers['Authorization'], 'Bearer op-token');
    expect(h.browser.downloads, hasLength(1));
    final (name, bytes, mime) = h.browser.downloads.single;
    expect(name, matches(RegExp(r'^jay-moderation-decisions-\d{4}-\d{2}-\d{2}\.csv$')));
    expect(mime, 'text/csv');
    expect(utf8.decode(bytes), h.backend.csv);
    expect(find.text('CSV downloaded.'), findsOneWidget);
  });

  testWidgets('CSV export pages with the before cursor and keeps one header', (tester) async {
    final backend = FakeBackend();
    // 100 decisions on page one (full page), 1 on page two.
    final page1 = [for (var i = 0; i < 100; i++) decisionJson(id: 200 - i)..['createdAt'] = '2026-10-${(i % 28 + 1).toString().padLeft(2, '0')}T08:00:00Z'];
    page1.last['createdAt'] = '2026-09-30T08:00:00Z';
    backend.overrides['GET /admin/decisions'] = (r) {
      final before = r.url.queryParameters['before'];
      if (r.url.queryParameters['format'] == 'csv') {
        return before == null
            ? http.Response('id,action\r\n1,"multi\nline"\r\n', 200)
            : http.Response('id,action\r\n2,dismiss\r\n', 200);
      }
      final body = before == null ? page1 : [decisionJson(id: 1)];
      return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
    };
    final h = await pumpAdmin(tester, backend: backend, location: '/audit');
    await tester.tap(find.byKey(const Key('export-csv')));
    await tester.pumpAndSettle();
    final csvBefores = backend.requests
        .where((r) => r.url.queryParameters['format'] == 'csv')
        .map((r) => r.url.queryParameters['before'])
        .toList();
    expect(csvBefores, [null, '2026-09-30T08:00:00.000Z']);
    expect(utf8.decode(h.browser.downloads.single.$2), 'id,action\r\n1,"multi\nline"\r\n2,dismiss\r\n');
  });

  group('API base URL', () {
    test('HTTPS and loopback HTTP are accepted, public HTTP is refused', () {
      expect(validateApiBaseUrl('https://calltype-beta.azurewebsites.net'), isNull);
      expect(validateApiBaseUrl('http://localhost:8080'), isNull);
      expect(validateApiBaseUrl('http://127.0.0.1:8080'), isNull);
      expect(validateApiBaseUrl('http://api.example.com'), isNotNull);
      expect(validateApiBaseUrl('ftp://x'), isNotNull);
      expect(validateApiBaseUrl('not a url'), isNotNull);
      expect(normalizeBaseUrl(' https://a.b/ '), 'https://a.b');
    });

    testWidgets('an unusable URL blocks the whole app, no login form', (tester) async {
      final api = AdminApi(baseUrl: 'http://api.example.com', client: FakeBackend().client);
      await tester.pumpWidget(AdminApp(
        api: api,
        session: SessionController(api),
        configError: validateApiBaseUrl(api.baseUrl),
        locale: const Locale('en'),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('refuses to send credentials'), findsOneWidget);
      expect(find.byKey(const Key('login-email')), findsNothing);
    });
  });
}
