import 'dart:convert';
import 'dart:typed_data';

import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/network/user_safety_api.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// Wire shapes from docs/superpowers/specs/2026-11-14-go-live.md (S2-S11).
class _Adapter implements HttpClientAdapter {
  _Adapter({this.status = 200, this.body});
  final int status;
  final Object? body;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      body == null ? '' : (body is String ? body as String : jsonEncode(body)),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

(ApiClient, _Adapter) _client({int status = 200, Object? body}) {
  final adapter = _Adapter(status: status, body: body);
  final dio = Dio(BaseOptions(baseUrl: 'https://api.test'))
    ..httpClientAdapter = adapter;
  return (ApiClient(baseUrl: 'https://api.test', dio: dio), adapter);
}

void main() {
  test('block and unblock use PUT / DELETE /blocks/{id}', () async {
    final (api, adapter) = _client(status: 204);
    await api.blockUser('dev-1');
    await api.unblockUser('dev-1');
    expect(adapter.requests.map((r) => '${r.method} ${r.path}'), [
      'PUT /blocks/dev-1',
      'DELETE /blocks/dev-1',
    ]);
  });

  test('getBlockedUsers parses rows and skips malformed ones', () async {
    final (api, _) = _client(
      body: {
        'blocks': [
          {
            'deviceId': 'ABC',
            'userHandle': 'CT-AAAA-BBBB',
            'displayName': 'Eve',
            'isBot': true,
            'createdAt': '2026-11-14T10:00:00Z',
          },
          {'userHandle': 'no id'},
          'junk',
        ],
      },
    );
    final users = await api.getBlockedUsers();
    expect(users, hasLength(1));
    expect(users.single.deviceId, 'abc');
    expect(users.single.userHandle, 'CT-AAAA-BBBB');
    expect(users.single.displayName, 'Eve');
    expect(users.single.isBot, isTrue);
    expect(users.single.createdAt, DateTime.utc(2026, 11, 14, 10));
    expect(parseBlockedUsers('nonsense'), isEmpty);
  });

  test('reportUser sends the contract body and returns the receipt', () async {
    final (api, adapter) = _client(body: {'reportId': 42, 'createdAt': 'x'});
    final number = await api.reportUser(
      'dev-1',
      reason: 'threats',
      category: 'illegal',
      goodFaith: true,
      groupId: 'g-1',
      messages: [
        ReportEvidence(
          text: 'a' * 5000,
          messageId: 'm1',
          sentAt: DateTime.utc(2026, 11, 14),
        ),
        const ReportEvidence(text: '   '),
      ],
    );
    expect(number, 42);
    final request = adapter.requests.single;
    expect(request.method, 'POST');
    expect(request.path, '/users/dev-1/report');
    final data = request.data as Map<String, dynamic>;
    expect(data['category'], 'illegal');
    expect(data['goodFaith'], isTrue);
    expect(data['groupId'], 'g-1');
    expect(data.containsKey('contactEmail'), isFalse);
    final messages = data['messages'] as List;
    expect(messages, hasLength(1), reason: 'empty texts are left out');
    expect((messages.single as Map)['text'], hasLength(4000));
    expect((messages.single as Map)['sentAt'], '2026-11-14T00:00:00.000Z');
  });

  test('userReportBody caps the evidence at 20 messages', () {
    final body = userReportBody(
      reason: 'x',
      messages: List.generate(30, (i) => ReportEvidence(text: '$i')),
    );
    expect(body['messages'], hasLength(20));
  });

  test('deleteAccount sends the auth key, deleteDevice the opt-in', () async {
    final (api, adapter) = _client(status: 204);
    await api.deleteAccount('acc-1', 'key');
    await api.deleteDevice('dev-1', includeCompanions: true);
    await api.deleteDevice('dev-2');
    expect(adapter.requests[0].method, 'DELETE');
    expect(adapter.requests[0].path, '/accounts/acc-1');
    expect(adapter.requests[0].data, {'authKey': 'key'});
    expect(adapter.requests[1].path, '/devices/dev-1');
    expect(adapter.requests[1].queryParameters, {'includeCompanions': 'true'});
    expect(adapter.requests[2].queryParameters, isEmpty);
  });

  test('exports return the raw JSON text', () async {
    final (api, adapter) = _client(body: '{"device":{"deviceId":"d"}}');
    expect(await api.exportDeviceJson('d'), '{"device":{"deviceId":"d"}}');
    expect(await api.exportAccountJson('a'), '{"device":{"deviceId":"d"}}');
    expect(adapter.requests.map((r) => r.path), [
      '/devices/d/export',
      '/accounts/a/export',
    ]);
  });

  test('apiErrorCode reads the code of an error body', () {
    final error = DioException(
      requestOptions: RequestOptions(),
      response: Response(
        requestOptions: RequestOptions(),
        statusCode: 409,
        data: {'code': 'device_is_auditor'},
      ),
    );
    expect(apiErrorCode(error), 'device_is_auditor');
    expect(apiErrorCode(StateError('x')), isNull);
  });
}
