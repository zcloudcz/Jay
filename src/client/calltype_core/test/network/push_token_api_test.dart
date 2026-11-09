import 'dart:convert';
import 'dart:typed_data';

import 'package:calltype_core/network/api_client.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// Records every request and answers with [status] / [body]. The request
/// shapes asserted below are copied from the notifications contract
/// (docs/superpowers/specs/2026-11-06-notifications.md, section 1.1).
class _Adapter implements HttpClientAdapter {
  _Adapter({this.status = 200, this.body});
  final int status;
  final Object? body;
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

(ApiClient, _Adapter) _client({int status = 200, Object? body}) {
  final adapter = _Adapter(status: status, body: body);
  final dio = Dio(BaseOptions(baseUrl: 'https://api.test'))
    ..httpClientAdapter = adapter;
  return (ApiClient(baseUrl: 'https://api.test', dio: dio), adapter);
}

void main() {
  test('updatePushToken PUTs platform, token and locale', () async {
    final (api, adapter) = _client(status: 204);
    await api.updatePushToken(
      deviceId: 'dev-1',
      token: 'abcdef',
      platform: 'apns',
      locale: 'cs',
    );
    final request = adapter.requests.single;
    expect(request.method, 'PUT');
    expect(request.path, '/devices/dev-1/push-token');
    expect(request.data, {
      'token': 'abcdef',
      'platform': 'apns',
      'locale': 'cs',
    });
  });

  test('updatePushToken leaves locale out when unknown', () async {
    final (api, adapter) = _client(status: 204);
    await api.updatePushToken(deviceId: 'dev-1', token: 't', platform: 'fcm');
    expect(adapter.requests.single.data, {'token': 't', 'platform': 'fcm'});
  });

  test('deletePushToken sends DELETE to the same route', () async {
    final (api, adapter) = _client(status: 204);
    await api.deletePushToken('dev-1');
    expect(adapter.requests.single.method, 'DELETE');
    expect(adapter.requests.single.path, '/devices/dev-1/push-token');
  });

  test('updatePushToken declares ringCalls only when true', () async {
    final (api, adapter) = _client(status: 204);
    await api.updatePushToken(
      deviceId: 'dev-1',
      token: 't',
      platform: 'fcm',
      ringCalls: true,
    );
    expect(adapter.requests.single.data, {
      'token': 't',
      'platform': 'fcm',
      'ringCalls': true,
    });
  });

  test('voip token PUT and DELETE follow the call ringing contract', () async {
    final (api, adapter) = _client(status: 204);
    await api.updateVoipToken(deviceId: 'dev-1', token: 'ab' * 32);
    await api.deleteVoipToken('dev-1');
    expect(adapter.requests[0].method, 'PUT');
    expect(adapter.requests[0].path, '/devices/dev-1/voip-token');
    expect(adapter.requests[0].data, {'token': 'ab' * 32});
    expect(adapter.requests[1].method, 'DELETE');
    expect(adapter.requests[1].path, '/devices/dev-1/voip-token');
  });

  test('getWebPushPublicKey reads publicKey', () async {
    final (api, adapter) = _client(body: {'publicKey': 'BPk_x'});
    expect(await api.getWebPushPublicKey(), 'BPk_x');
    expect(adapter.requests.single.path, '/push/webpush-key');
  });

  test('getWebPushPublicKey is null when Web Push is not configured', () async {
    final (api, _) = _client(status: 404, body: {'error': 'not_found'});
    expect(await api.getWebPushPublicKey(), isNull);
  });
}
