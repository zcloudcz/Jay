import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jay_admin/api/admin_api.dart';
import 'package:jay_admin/app.dart';
import 'package:jay_admin/platform/browser.dart';
import 'package:jay_admin/session.dart';

/// Ids reused by fixtures and assertions.
const chA = '11111111-1111-1111-1111-111111111111';
const chB = '22222222-2222-2222-2222-222222222222';
const postA = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const operatorId = '99999999-9999-9999-9999-999999999999';

/// 1x1 transparent PNG, so Image.memory has real bytes to decode.
final pngBytes = Uint8List.fromList(base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
));

String iso(DateTime t) => t.toUtc().toIso8601String();

Map<String, dynamic> channelJson({
  String id = chA,
  String handle = 'CH-AAAA-1111',
  String name = 'Cheap Deals',
  String status = 'active',
  DateTime? suspendedUntil,
  bool deleted = false,
}) => {
  'channelId': id,
  'handle': handle,
  'name': name,
  'description': 'Best prices in town',
  'followerCount': 1234,
  'status': status,
  'suspendedUntil': suspendedUntil == null ? null : iso(suspendedUntil),
  'deleted': deleted,
  'createdAt': '2026-10-01T10:00:00Z',
  'ownerHandle': 'CT-OWNR-0001',
};

Map<String, dynamic> postJson({
  String id = postA,
  String body = 'Send me your bank password to win',
  String? blob,
  bool byBot = false,
  String createdAt = '2026-11-04T09:00:00Z',
}) => {
  'postId': id,
  'kind': blob == null ? 'text' : 'image',
  'body': body,
  'attachmentBlobPath': blob,
  'createdAt': createdAt,
  'deleted': false,
  'byBot': byBot,
};

Map<String, dynamic> decisionJson({String action = 'remove_post', int id = 7}) => {
  'decisionId': id,
  'action': action,
  'postId': action == 'remove_post' ? postA : null,
  'ground': 'terms',
  'rule': 'K4',
  'legalGround': null,
  'explanation': 'Phishing for bank credentials.',
  'suspendedUntil': null,
  'basedOnReports': true,
  'automated': false,
  'createdAt': '2026-10-20T08:00:00Z',
  'operatorAccountId': operatorId,
  'reportCount': 2,
  'channelId': chA,
};

/// In-memory operator API that answers with the contract's JSON shapes
/// (docs/superpowers/specs/2026-11-05-channel-moderation-contract.md 4.x),
/// records every request and lets a test override any route.
class FakeBackend {
  final requests = <http.Request>[];

  /// Next response of POST /admin/session, e.g. an error.
  http.Response? sessionResponse;

  /// When set, every authenticated route answers 401 (expired token).
  bool rejectToken = false;

  Map<String, dynamic> summary = {
    'openReports': 5,
    'openSubjects': 2,
    'oldestOpenAt': iso(DateTime.now().toUtc().subtract(const Duration(hours: 3))),
    'suspendedChannels': 1,
    'decisionsLast30Days': 4,
  };

  late List<Map<String, dynamic>> subjects = [
    {
      'subjectType': 'post',
      'channelId': chA,
      'postId': postA,
      'status': 'open',
      'reportCount': 3,
      'categories': {'illegal': 1, 'terms': 2},
      'firstReportedAt': iso(DateTime.now().toUtc().subtract(const Duration(hours: 3))),
      'lastReportedAt': iso(DateTime.now().toUtc().subtract(const Duration(hours: 1))),
      'latestReason': 'This is a phishing scam asking for passwords',
      'channel': channelJson(),
      'post': postJson(blob: 'channel-media/$chA/abc.png'),
      'priorDecisions': [decisionJson()],
    },
    {
      'subjectType': 'channel',
      'channelId': chB,
      'postId': null,
      'status': 'open',
      'reportCount': 1,
      'categories': {'spam': 1},
      'firstReportedAt': iso(DateTime.now().toUtc().subtract(const Duration(days: 2))),
      'lastReportedAt': iso(DateTime.now().toUtc().subtract(const Duration(days: 2))),
      'latestReason': 'Posts the same ad every minute',
      'channel': channelJson(id: chB, handle: 'CH-BBBB-2222', name: 'Ad Blaster'),
      'post': null,
      'priorDecisions': <Object>[],
    },
  ];

  Map<String, dynamic> subjectDetail({String channelId = chA, String? postId}) => {
    'channel': channelId == chA
        ? channelJson()
        : channelJson(id: chB, handle: 'CH-BBBB-2222', name: 'Ad Blaster', status: 'suspended', suspendedUntil: DateTime.utc(2026, 12, 1)),
    'post': postId == null ? null : postJson(blob: 'channel-media/$chA/abc.png'),
    'context': [
      postJson(id: 'c0000000-0000-0000-0000-000000000001', body: 'Earlier post', createdAt: '2026-11-03T09:00:00Z'),
      postJson(id: 'c0000000-0000-0000-0000-000000000002', body: 'Later post by bot', byBot: true, createdAt: '2026-11-05T09:00:00Z'),
    ],
    'reports': [
      {
        'reportId': 41,
        'category': 'illegal',
        'reason': 'Fraud: asks for bank password',
        'contactEmail': 'reporter@example.com',
        'goodFaith': true,
        'createdAt': '2026-11-04T10:00:00Z',
        'status': 'open',
      },
      {
        'reportId': 42,
        'category': 'terms',
        'reason': 'scam',
        'contactEmail': null,
        'goodFaith': false,
        'createdAt': '2026-11-04T11:00:00Z',
        'status': 'open',
      },
    ],
    'decisions': [decisionJson()],
  };

  String csv = 'decisionId,action,channelId\r\n7,remove_post,$chA\r\n';

  /// Overrides keyed by "METHOD /path".
  final overrides = <String, http.Response Function(http.Request)>{};

  http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  static http.Response error(int status, String code) => http.Response(
    jsonEncode({'error': 'x', 'code': code}),
    status,
    headers: {'content-type': 'application/json'},
  );

  Future<http.Response> handle(http.Request r) async {
    requests.add(r);
    final key = '${r.method} ${r.url.path}';
    final o = overrides[key];
    if (o != null) return o(r);
    if (key == 'POST /admin/session') {
      return sessionResponse ??
          _json({
            'token': 'op-token',
            'expiresAt': iso(DateTime.now().toUtc().add(const Duration(minutes: 30))),
            'accountId': operatorId,
            'email': 'op@zcloud.cz',
          });
    }
    if (rejectToken || r.headers['Authorization'] != 'Bearer op-token') {
      return http.Response('', 401);
    }
    final p = r.url.path;
    if (key == 'GET /admin/summary') return _json(summary);
    if (key == 'GET /admin/reports') {
      final cat = r.url.queryParameters['category'];
      final type = r.url.queryParameters['subjectType'];
      final items = subjects.where((s) {
        if (cat != null && !(s['categories'] as Map).containsKey(cat)) return false;
        if (type != null && s['subjectType'] != type) return false;
        return true;
      }).toList();
      return _json({'items': items, 'counts': {'open': 2, 'resolved': 9}, 'nextCursor': null});
    }
    if (r.method == 'GET' && p.startsWith('/admin/subjects/')) {
      return _json(subjectDetail(channelId: p.split('/').last, postId: r.url.queryParameters['postId']));
    }
    if (r.method == 'GET' && p.contains('/attachments/')) {
      return http.Response.bytes(pngBytes, 200, headers: {'content-type': 'image/png'});
    }
    if (key == 'POST /admin/decisions') {
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      return _json({...decisionJson(action: body['action'] as String, id: 8), ...body}, 201);
    }
    if (key == 'GET /admin/channels') {
      return _json([channelJson(), channelJson(id: chB, handle: 'CH-BBBB-2222', name: 'Ad Blaster', status: 'suspended', suspendedUntil: DateTime.utc(2026, 12, 1))]);
    }
    if (key == 'GET /admin/decisions') {
      if (r.url.queryParameters['format'] == 'csv') {
        return http.Response(csv, 200, headers: {'content-type': 'text/csv'});
      }
      return _json([decisionJson()]);
    }
    return http.Response('', 404);
  }

  http.Client get client => MockClient(handle);

  Iterable<http.Request> where(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == path);
}

class FakeBrowser implements BrowserActions {
  final downloads = <(String, Uint8List, String)>[];
  final opened = <Uri>[];

  @override
  void download(String fileName, Uint8List bytes, String mimeType) => downloads.add((fileName, bytes, mimeType));

  @override
  void openUrl(Uri url) => opened.add(url);
}

class Harness {
  Harness(this.backend, this.api, this.session, this.browser);
  final FakeBackend backend;
  final AdminApi api;
  final SessionController session;
  final FakeBrowser browser;
}

/// Pumps the whole app (router, l10n, theme) against [backend]. With
/// [loggedIn] the session is created first through the fake API, exactly
/// like the login form does.
Future<Harness> pumpAdmin(
  WidgetTester tester, {
  FakeBackend? backend,
  bool loggedIn = true,
  String location = '/overview',
  Locale locale = const Locale('en'),
  Size size = const Size(1400, 1000),
  DateTime Function()? clock,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final b = backend ?? FakeBackend();
  final api = AdminApi(baseUrl: 'https://api.example.test', client: b.client);
  final session = SessionController(api, clock: clock);
  final browser = FakeBrowser();
  if (loggedIn) {
    await session.login(email: 'op@zcloud.cz', passphrase: 'pass', code: '123456');
  }
  await tester.pumpWidget(
    AdminApp(api: api, session: session, browser: browser, initialLocation: location, locale: locale),
  );
  await tester.pumpAndSettle();
  return Harness(b, api, session, browser);
}

/// The router's current location (path + query), as the address bar shows it
/// after the hash.
String currentLocation(WidgetTester tester) {
  final ctx = tester.element(find.byType(Scaffold).first);
  return GoRouter.of(ctx).routeInformationProvider.value.uri.toString();
}
