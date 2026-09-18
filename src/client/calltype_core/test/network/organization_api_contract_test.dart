import 'dart:convert';
import 'dart:typed_data';

import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/network/organization_api.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// Replays the server's REAL response shapes (contracts §E01, verified by the
/// live E2E run in jay_archiver/test/e2e). Every case here was a crash or a
/// 4xx in the app before: the client had been written against an assumed
/// shape and only ever tested against mocks of that same assumption.
class _FakeServer implements HttpClientAdapter {
  _FakeServer(this._routes);

  /// `'METHOD /path'` → (status, json body or null for an empty body).
  final Map<String, (int, Object?)> _routes;
  final requests = <String, String?>{};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final key = '${options.method} ${options.path}';
    final bytes = requestStream == null
        ? <int>[]
        : (await requestStream.toList()).expand((chunk) => chunk).toList();
    requests[key] = bytes.isEmpty ? null : utf8.decode(bytes);
    final (status, body) = _routes[key] ?? (404, null);
    return ResponseBody.fromString(
      body == null ? '' : jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const _mine = [
  {
    'organizationId': 'org-1',
    'name': 'Acme',
    'role': 'OrgAdmin',
    'archiveLevel': 'Metadata',
    'auditorDeviceId': 'dev-9',
  },
];

void main() {
  (ApiClient, _FakeServer) client(Map<String, (int, Object?)> routes) {
    final server = _FakeServer(routes);
    final dio = Dio(BaseOptions(baseUrl: 'http://test'))
      ..httpClientAdapter = server;
    return (ApiClient(baseUrl: 'http://test', dio: dio), server);
  }

  test('createOrganization: 201 without a role means the caller is owner', () async {
    final (api, _) = client({
      'POST /orgs': (201, {'organizationId': 'org-1', 'name': 'Acme'}),
    });

    final org = await api.createOrganization('Acme');

    expect(org.organizationId, 'org-1');
    expect(org.role, 'owner');
    expect(org.isAdmin, isTrue);
  });

  test('createInvite sends a JSON body (a bodyless POST is a 400)', () async {
    final (api, server) = client({
      'POST /orgs/org-1/invites': (200, {'code': 'ABC', 'expiresAt': '2026-09-21T00:00:00Z'}),
    });

    expect((await api.createInvite('org-1')).code, 'ABC');
    expect(server.requests['POST /orgs/org-1/invites'], '{}');
  });

  test('getOrganization takes the caller role from /orgs/mine', () async {
    final (api, _) = client({'GET /orgs/mine': (200, _mine)});

    final org = await api.getOrganization('org-1');

    expect(org.role, 'orgAdmin');
    expect(org.auditorDeviceId, 'dev-9');
  });

  test('getOrganizationMembers reads the members array of GET /orgs/{id}', () async {
    final (api, _) = client({
      'GET /orgs/org-1': (200, {
        'organizationId': 'org-1',
        'name': 'Acme',
        'members': [
          {'accountId': 'acc-1', 'role': 'Owner', 'addedAt': '2026-09-18T00:00:00Z'},
        ],
      }),
    });

    final members = await api.getOrganizationMembers('org-1');

    expect(members.single.accountId, 'acc-1');
    expect(members.single.role, 'owner');
  });

  test('updateOrganization copes with the 204 and re-reads the organization', () async {
    final (api, _) = client({
      'PATCH /orgs/org-1': (204, null),
      'GET /orgs/mine': (200, _mine),
    });

    expect((await api.updateOrganization('org-1', name: 'Acme')).name, 'Acme');
  });

  test('getOrganizationEnrollments reads device ids only', () async {
    final (api, _) = client({
      'GET /orgs/org-1/enrollments': (200, [
        {'deviceId': 'dev-9', 'enrolledAt': '2026-09-18T00:00:00Z'},
      ]),
    });

    final enrollments = await api.getOrganizationEnrollments('org-1');

    expect(enrollments.single.deviceId, 'dev-9');
    expect(enrollments.single.enrolledAt, '2026-09-18T00:00:00Z');
  });

  test('getAuditArchiveStatus reads the extended AuditRecordCountDto shape', () async {
    final (api, _) = client({
      'GET /orgs/org-1/audit/records/count': (200, {
        'count': 3,
        'lastSequence': 3,
        'lastHash': 'AA'.padRight(64, '0'),
        'lastArchivedAt': '2026-09-18T12:00:00Z',
        'pendingForAuditor': 2,
        'oldestPendingAt': '2026-09-18T11:55:00Z',
      }),
    });

    final status = await api.getAuditArchiveStatus('org-1');

    expect(status.count, 3);
    expect(status.lastSequence, 3);
    expect(status.lastArchivedAt, DateTime.parse('2026-09-18T12:00:00Z'));
    expect(status.pendingForAuditor, 2);
    expect(status.oldestPendingAt, DateTime.parse('2026-09-18T11:55:00Z'));
  });

  test('getAuditArchiveStatus copes with an archiver that has never run', () async {
    final (api, _) = client({
      'GET /orgs/org-1/audit/records/count': (200, {
        'count': 0,
        'lastSequence': 0,
        'lastHash': null,
        'lastArchivedAt': null,
        'pendingForAuditor': 0,
        'oldestPendingAt': null,
      }),
    });

    final status = await api.getAuditArchiveStatus('org-1');

    expect(status.lastHash, isNull);
    expect(status.lastArchivedAt, isNull);
    expect(status.oldestPendingAt, isNull);
  });

  test('getAuditRecordCount (older callers) still reads just the count', () async {
    final (api, _) = client({
      'GET /orgs/org-1/audit/records/count': (200, {
        'count': 5,
        'lastSequence': 5,
        'lastHash': 'BB'.padRight(64, '0'),
        'lastArchivedAt': '2026-09-18T12:00:00Z',
        'pendingForAuditor': 0,
        'oldestPendingAt': null,
      }),
    });

    expect(await api.getAuditRecordCount('org-1'), 5);
  });
}
