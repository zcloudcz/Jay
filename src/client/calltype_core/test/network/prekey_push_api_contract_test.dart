import 'dart:convert';
import 'dart:typed_data';

import 'package:calltype_core/network/api_client.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// X0 REST additions against the response shapes COPIED from the frozen
/// contracts (S §4.2 pre-keys, N §4.2 push token, contracts §2.2) — not
/// from the client's own assumptions.
class _FakeServer implements HttpClientAdapter {
  _FakeServer(this._routes);

  final Map<String, (int, Object?)> _routes;
  final requests = <String, String?>{};
  final queries = <String, Map<String, dynamic>>{};

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
    queries[key] = options.queryParameters;
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

void main() {
  (ApiClient, _FakeServer) client(Map<String, (int, Object?)> routes) {
    final server = _FakeServer(routes);
    final dio = Dio(BaseOptions(baseUrl: 'http://test'))
      ..httpClientAdapter = server;
    return (ApiClient(baseUrl: 'http://test', dio: dio), server);
  }

  test('GET prekeys parses the contract body', () async {
    final (api, _) = client({
      'GET /devices/d1/prekeys': (
        200,
        {
          'oneTimePreKeyCount': 37,
          'oneTimePreKeyIds': [101, 102, 140],
          'maxOneTimePreKeys': 200,
          'signedPreKeyId': 3,
          'signedPreKeyUpdatedAt': '2026-09-29T10:00:00+00:00',
        },
      ),
    });
    final status = await api.getPreKeyStatus('d1');
    expect(status.oneTimePreKeyCount, 37);
    expect(status.oneTimePreKeyIds, [101, 102, 140]);
    expect(status.maxOneTimePreKeys, 200);
    expect(status.signedPreKeyId, 3);
    expect(status.signedPreKeyUpdatedAt, DateTime.utc(2026, 9, 29, 10));
  });

  test('GET prekeys before the first rotation has a null timestamp', () async {
    final (api, _) = client({
      'GET /devices/d1/prekeys': (
        200,
        {
          'oneTimePreKeyCount': 0,
          'oneTimePreKeyIds': <int>[],
          'maxOneTimePreKeys': 200,
          'signedPreKeyId': 1,
          'signedPreKeyUpdatedAt': null,
        },
      ),
    });
    expect((await api.getPreKeyStatus('d1')).signedPreKeyUpdatedAt, isNull);
  });

  test('POST prekeys sends {oneTimePreKeys} and parses {stored,total}',
      () async {
    final (api, server) = client({
      'POST /devices/d1/prekeys': (200, {'stored': 63, 'total': 100}),
    });
    final result = await api.uploadOneTimePreKeys('d1', [
      {'keyId': 101, 'publicKey': 'AAAA'},
    ]);
    expect(result.stored, 63);
    expect(result.total, 100);
    expect(jsonDecode(server.requests['POST /devices/d1/prekeys']!), {
      'oneTimePreKeys': [
        {'keyId': 101, 'publicKey': 'AAAA'},
      ],
    });
  });

  test('PUT signed-prekey sends keyId, publicKey, signature', () async {
    final (api, server) = client({
      'PUT /devices/d1/signed-prekey': (204, null),
    });
    await api.updateSignedPreKey(
      'd1',
      keyId: 4,
      publicKey: 'pk',
      signature: 'sig',
    );
    expect(jsonDecode(server.requests['PUT /devices/d1/signed-prekey']!), {
      'keyId': 4,
      'publicKey': 'pk',
      'signature': 'sig',
    });
  });

  test('409 stale_signed_prekey surfaces as a DioException', () async {
    final (api, _) = client({
      'PUT /devices/d1/signed-prekey': (
        409,
        {'error': 'stale', 'code': 'stale_signed_prekey', 'currentKeyId': 5},
      ),
    });
    await expectLater(
      api.updateSignedPreKey('d1', keyId: 4, publicKey: 'p', signature: 's'),
      throwsA(isA<DioException>()),
    );
  });

  test('registerPushToken sends only the fields that are set', () async {
    final (api, server) = client({
      'PUT /devices/d1/push-token': (204, null),
    });
    await api.registerPushToken(
      deviceId: 'd1',
      token: 'voip-hex',
      platform: PushPlatforms.apnsVoip,
      environment: 'sandbox',
      pushKey: 'a2V5',
    );
    expect(jsonDecode(server.requests['PUT /devices/d1/push-token']!), {
      'token': 'voip-hex',
      'platform': 'apns-voip',
      'environment': 'sandbox',
      'pushKey': 'a2V5',
    });
    await api.registerPushToken(
      deviceId: 'd1',
      token: 'fcm-token',
      platform: PushPlatforms.fcm,
    );
    expect(jsonDecode(server.requests['PUT /devices/d1/push-token']!), {
      'token': 'fcm-token',
      'platform': 'fcm',
    });
  });

  test('deletePushToken passes the platform as a query parameter', () async {
    final (api, server) = client({
      'DELETE /devices/d1/push-token': (204, null),
    });
    await api.deletePushToken(deviceId: 'd1', platform: PushPlatforms.apns);
    expect(server.queries['DELETE /devices/d1/push-token'], {
      'platform': 'apns',
    });
  });

  test('deleteDevice calls DELETE /devices/{id}', () async {
    final (api, server) = client({'DELETE /devices/d1': (204, null)});
    await api.deleteDevice('d1');
    expect(server.requests.keys, ['DELETE /devices/d1']);
  });
}
