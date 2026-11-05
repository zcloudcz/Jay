import 'dart:convert';
import 'dart:typed_data';

import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/network/channel_dtos.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// Channel moderation (contract 2026-11-05-channel-moderation, section 5).
/// Every JSON literal below is copied from the contract, not from the
/// client's own assumptions: the server is built in parallel against it.

/// Records requests and answers with [status] / [body] (null = no body).
class _Adapter implements HttpClientAdapter {
  _Adapter(this.body, {this.status = 200});
  final Object? body;
  final int status;
  final requests = <({String method, String path, Object? data})>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add((
      method: options.method,
      path: options.path,
      data: options.data,
    ));
    if (body == null) return ResponseBody.fromString('', status);
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

(ApiClient, _Adapter) _client(Object? body, {int status = 200}) {
  final adapter = _Adapter(body, status: status);
  final dio = Dio(BaseOptions(baseUrl: 'https://api.test'))
    ..httpClientAdapter = adapter;
  return (ApiClient(baseUrl: 'https://api.test', dio: dio), adapter);
}

Map<String, dynamic> _json(String s) => jsonDecode(s) as Map<String, dynamic>;

void main() {
  group('DTO fields with safe defaults', () {
    test('ChannelInfo reads status + suspendedUntil', () {
      final until = DateTime.now().toUtc().add(const Duration(days: 3));
      final info = ChannelInfo.fromJson({
        'channelId': 'c1',
        'handle': 'CH-AAAA-BBBB',
        'name': 'News',
        'role': 'publisher',
        'status': 'suspended',
        'suspendedUntil': until.toIso8601String(),
      });
      expect(info.status, 'suspended');
      expect(info.suspendedUntil, until);
      expect(info.isSuspended, isTrue);
      expect(info.canPublish, isTrue);
      expect(info.canEdit, isFalse, reason: 'publisher may not edit');
    });

    test('ChannelInfo from an old server is active', () {
      final info = ChannelInfo.fromJson({'channelId': 'c1', 'role': 'admin'});
      expect(info.status, 'active');
      expect(info.suspendedUntil, isNull);
      expect(info.isSuspended, isFalse);
      expect(info.canEdit, isTrue);
    });

    test('an expired suspension is no longer suspended', () {
      final info = ChannelInfo.fromJson({
        'channelId': 'c1',
        'status': 'suspended',
        'suspendedUntil': '2020-01-01T00:00:00Z',
      });
      expect(info.isSuspended, isFalse);
    });

    test('ChannelPostDto.byBot defaults to false', () {
      final post = ChannelPostDto.fromJson(
        _json('{"channelId":"c1","postId":"p1","byBot":true}'),
      );
      expect(post.byBot, isTrue);
      expect(
        ChannelPostDto.fromJson({'channelId': 'c1', 'postId': 'p2'}).byBot,
        isFalse,
      );
    });

    test('ChannelAdminDto reads role, isBot, handle, displayName', () {
      final admins = parseList(
        jsonDecode(
          '[{"deviceId":"d1","addedAt":"2026-11-05T10:00:00+00:00",'
          '"role":"publisher","isBot":true,"handle":"CT-BOT0-0001",'
          '"displayName":"Newsletter"},'
          '{"deviceId":"d2"}]',
        ),
      ).map(ChannelAdminDto.fromJson).toList();
      expect(admins.first.role, 'publisher');
      expect(admins.first.isPublisher, isTrue);
      expect(admins.first.isBot, isTrue);
      expect(admins.first.handle, 'CT-BOT0-0001');
      expect(admins.first.displayName, 'Newsletter');
      // Old server: admin, human, no profile.
      expect(admins.last.role, 'admin');
      expect(admins.last.isBot, isFalse);
      expect(admins.last.handle, isNull);
      expect(admins.last.displayName, isNull);
    });
  });

  test('ModerationStatement parses the contract shape', () {
    final s = ModerationStatement.fromJson(
      _json(
        '{"decisionId":12,"action":"suspend_channel","postId":null,'
        '"ground":"terms","rule":"K3","legalGround":null,'
        '"explanation":"Repeated spam.",'
        '"suspendedUntil":"2026-11-12T10:00:00Z","basedOnReports":true,'
        '"automated":false,"createdAt":"2026-11-05T10:00:00Z"}',
      ),
    );
    expect(s.decisionId, 12);
    expect(s.action, 'suspend_channel');
    expect(s.postId, isNull);
    expect(s.ground, 'terms');
    expect(s.rule, 'K3');
    expect(s.legalGround, isNull);
    expect(s.explanation, 'Repeated spam.');
    expect(s.suspendedUntil, DateTime.utc(2026, 11, 12, 10));
    expect(s.basedOnReports, isTrue);
    expect(s.createdAt, DateTime.utc(2026, 11, 5, 10));
  });

  test('MyReport parses the contract shape', () {
    final r = MyReport.fromJson(
      _json(
        '{"reportId":42,"channelId":"c1","channelName":"News",'
        '"channelHandle":"CH-AAAA-BBBB","postId":"p1","category":"illegal",'
        '"createdAt":"2026-11-05T10:00:00Z","status":"actioned",'
        '"resolvedAt":"2026-11-06T09:00:00Z"}',
      ),
    );
    expect(r.reportId, 42);
    expect(r.channelName, 'News');
    expect(r.channelHandle, 'CH-AAAA-BBBB');
    expect(r.postId, 'p1');
    expect(r.category, 'illegal');
    expect(r.status, 'actioned');
    expect(r.resolvedAt, DateTime.utc(2026, 11, 6, 9));
  });

  test('rules URL: cs or en, anchor only for known rule ids', () {
    expect(
      channelRulesUrl('cs', rule: 'K3'),
      'https://jay.zcloud.cz/legal/channels-cs.html#K3',
    );
    expect(
      channelRulesUrl('de'),
      'https://jay.zcloud.cz/legal/channels-en.html',
    );
    expect(
      channelRulesUrl('en', rule: 'X1'),
      'https://jay.zcloud.cz/legal/channels-en.html',
    );
    expect(channelRuleIds, hasLength(10));
    expect(channelReportCategories, ['illegal', 'terms', 'spam']);
    expect(ChannelErrorCodes.channelSuspended, 'channel_suspended');
    expect(ChannelErrorCodes.botPostLimit, 'bot_post_limit');
  });

  group('ApiClient', () {
    test('reportChannel posts category, e-mail, good faith; returns the '
        'report number', () async {
      final (api, adapter) = _client({
        'reportId': 77,
        'createdAt': '2026-11-05T10:00:00Z',
      });
      final id = await api.reportChannel(
        'c1',
        postId: 'p1',
        reason: 'hate',
        category: 'illegal',
        contactEmail: 'a@b.cz',
        goodFaith: true,
      );
      expect(id, 77);
      final request = adapter.requests.single;
      expect(request.method, 'POST');
      expect(request.path, '/channels/c1/report');
      expect(request.data, {
        'postId': 'p1',
        'reason': 'hate',
        'category': 'illegal',
        'contactEmail': 'a@b.cz',
        'goodFaith': true,
      });
    });

    test('reportChannel defaults and an old server answering 204', () async {
      final (api, adapter) = _client(null, status: 204);
      expect(await api.reportChannel('c1', reason: 'spam'), 0);
      expect(adapter.requests.single.data, {
        'reason': 'spam',
        'category': 'terms',
        'goodFaith': false,
      });
    });

    test('getMyReports', () async {
      final (api, adapter) = _client([
        {
          'reportId': 1,
          'channelId': 'c1',
          'channelName': 'News',
          'channelHandle': 'CH-AAAA-BBBB',
          'postId': null,
          'category': 'terms',
          'createdAt': '2026-11-05T10:00:00Z',
          'status': 'open',
          'resolvedAt': null,
        },
      ]);
      final reports = await api.getMyReports();
      expect(reports.single.reportId, 1);
      expect(reports.single.status, 'open');
      expect(adapter.requests.single.path, '/channels/reports/mine');
    });

    test('getChannelModeration', () async {
      final (api, adapter) = _client([
        {
          'decisionId': 3,
          'action': 'remove_post',
          'postId': 'p1',
          'ground': 'illegal',
          'rule': null,
          'legalGround': 'Section 356 Criminal Code',
          'explanation': 'Removed.',
          'suspendedUntil': null,
          'basedOnReports': true,
          'automated': false,
          'createdAt': '2026-11-05T10:00:00Z',
        },
      ]);
      final statements = await api.getChannelModeration('c1');
      expect(statements.single.legalGround, 'Section 356 Criminal Code');
      expect(adapter.requests.single.path, '/channels/c1/moderation');
    });

    test('setChannelAdmin sends the role; removal is a DELETE', () async {
      final (api, adapter) = _client(null, status: 204);
      await api.setChannelAdmin('c1', 'd1', admin: true, role: 'publisher');
      await api.setChannelAdmin('c1', 'd2', admin: true);
      await api.setChannelAdmin('c1', 'd3', admin: false);
      expect(adapter.requests[0].method, 'PUT');
      expect(adapter.requests[0].path, '/channels/c1/admins/d1');
      expect(adapter.requests[0].data, {'role': 'publisher'});
      expect(adapter.requests[1].data, {'role': 'admin'});
      expect(adapter.requests[2].method, 'DELETE');
      expect(adapter.requests[2].path, '/channels/c1/admins/d3');
    });
  });
}
