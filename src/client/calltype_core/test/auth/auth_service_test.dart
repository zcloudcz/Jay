import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:calltype_core/auth/auth_service.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/storage/secret_store.dart';

/// Tests for [AuthService] and the ApiClient auth interceptor.
///
/// HTTP is faked at the Dio adapter level (no real network), and
/// SecureStorage is replaced with an in-memory fake — platform channels
/// are never touched. This lets us verify the full token lifecycle:
/// fetch, cache, forced refresh, Bearer attachment, and the 401 retry.
void main() {
  group('AuthService', () {
    test('returns null when device is not registered', () async {
      final storage = _InMemorySecureStorage(); // no deviceId / secret
      final adapter = _FakeAdapter((_) => _tokenResponse());
      final service = AuthService(
        secureStorage: storage,
        baseUrl: 'https://api.test',
        dio: _dioWith(adapter),
      );

      final token = await service.getToken();

      expect(token, isNull);
      // No registration = no credentials = the token endpoint must not
      // even be called.
      expect(adapter.requestCount, 0);
    });

    test('exchanges device secret for a token and caches it', () async {
      final storage = _registeredStorage();
      final adapter = _FakeAdapter((options) {
        // Verify the exchange carries the stored credentials.
        expect(options.path, '/auth/token');
        final body = options.data as Map<String, dynamic>;
        expect(body['deviceId'], 'device-123');
        expect(body['deviceSecret'], 'secret-abc');
        return _tokenResponse(token: 'jwt-1');
      });
      final service = AuthService(
        secureStorage: storage,
        baseUrl: 'https://api.test',
        dio: _dioWith(adapter),
      );

      final token1 = await service.getToken();
      final token2 = await service.getToken();

      expect(token1, 'jwt-1');
      expect(token2, 'jwt-1');
      // Second call must come from the cache — the token is valid for
      // 24 hours and the auth endpoint is rate-limited to 10 req/min.
      expect(adapter.requestCount, 1);
    });

    test('concurrent callers share one in-flight token exchange', () async {
      final storage = _registeredStorage();
      final adapter = _FakeAdapter((_) => _tokenResponse());
      final service = AuthService(
        secureStorage: storage,
        baseUrl: 'https://api.test',
        dio: _dioWith(adapter),
      );

      // Fire several requests before the first completes — they must all
      // join the same exchange instead of hammering the rate-limited endpoint.
      final tokens = await Future.wait([
        service.getToken(),
        service.getToken(),
        service.getToken(),
      ]);

      expect(tokens, everyElement(isNotNull));
      expect(adapter.requestCount, 1);
    });

    test('forceRefresh bypasses the cache', () async {
      final storage = _registeredStorage();
      var counter = 0;
      final adapter = _FakeAdapter((_) => _tokenResponse(token: 'jwt-${++counter}'));
      final service = AuthService(
        secureStorage: storage,
        baseUrl: 'https://api.test',
        dio: _dioWith(adapter),
      );

      final first = await service.getToken();
      final refreshed = await service.getToken(forceRefresh: true);

      expect(first, 'jwt-1');
      expect(refreshed, 'jwt-2');
      expect(adapter.requestCount, 2);
    });

    test('clearToken drops the cache', () async {
      final storage = _registeredStorage();
      final adapter = _FakeAdapter((_) => _tokenResponse());
      final service = AuthService(
        secureStorage: storage,
        baseUrl: 'https://api.test',
        dio: _dioWith(adapter),
      );

      await service.getToken();
      service.clearToken();
      await service.getToken();

      expect(adapter.requestCount, 2);
    });
  });

  group('ApiClient auth interceptor', () {
    test('attaches Bearer header to API requests', () async {
      final authService = _authServiceReturning('jwt-xyz');

      String? capturedAuth;
      final apiAdapter = _FakeAdapter((options) {
        capturedAuth = options.headers['Authorization'] as String?;
        return _jsonResponse({'deviceId': 'peer', 'identityKey': 'ik'});
      });
      final client = ApiClient(
        baseUrl: 'https://api.test',
        authService: authService,
        dio: _dioWith(apiAdapter),
      );

      await client.getKeyBundle('peer');

      expect(capturedAuth, 'Bearer jwt-xyz');
    });

    test('sends request without header when device not registered', () async {
      final authService = AuthService(
        secureStorage: _InMemorySecureStorage(),
        baseUrl: 'https://api.test',
        dio: _dioWith(_FakeAdapter((_) => _tokenResponse())),
      );

      Map<String, dynamic>? capturedHeaders;
      final apiAdapter = _FakeAdapter((options) {
        capturedHeaders = options.headers;
        return _jsonResponse({
          'deviceId': 'd',
          'userHandle': 'CT-AAAA-BBBB',
          'deviceSecret': 's',
        });
      });
      final client = ApiClient(
        baseUrl: 'https://api.test',
        authService: authService,
        dio: _dioWith(apiAdapter),
      );

      // Registration is the one call that legitimately runs unauthenticated.
      await client.registerDevice(
        identityKey: 'ik',
        signedPreKey: 'spk',
        oneTimePreKeys: const [],
      );

      expect(capturedHeaders?['Authorization'], isNull);
    });

    test('retries once with a fresh token after 401', () async {
      var tokenCounter = 0;
      final authService = AuthService(
        secureStorage: _registeredStorage(),
        baseUrl: 'https://api.test',
        dio: _dioWith(
          _FakeAdapter((_) => _tokenResponse(token: 'jwt-${++tokenCounter}')),
        ),
      );

      final seenAuthHeaders = <String?>[];
      final apiAdapter = _FakeAdapter((options) {
        seenAuthHeaders.add(options.headers['Authorization'] as String?);
        // First attempt is rejected (e.g. server restarted with a new
        // signing key); the replay with a fresh token succeeds.
        if (seenAuthHeaders.length == 1) {
          return _jsonResponse({'error': 'expired'}, statusCode: 401);
        }
        return _jsonResponse({'deviceId': 'peer', 'identityKey': 'ik'});
      });
      final client = ApiClient(
        baseUrl: 'https://api.test',
        authService: authService,
        dio: _dioWith(apiAdapter),
      );

      final bundle = await client.getKeyBundle('peer');

      expect(bundle['identityKey'], 'ik');
      expect(seenAuthHeaders, ['Bearer jwt-1', 'Bearer jwt-2']);
    });

    test('does not retry twice — genuine 401 surfaces to the caller', () async {
      final authService = _authServiceReturning('jwt-bad');

      var attempts = 0;
      final apiAdapter = _FakeAdapter((_) {
        attempts++;
        return _jsonResponse({'error': 'nope'}, statusCode: 401);
      });
      final client = ApiClient(
        baseUrl: 'https://api.test',
        authService: authService,
        dio: _dioWith(apiAdapter),
      );

      await expectLater(
        client.getKeyBundle('peer'),
        throwsA(isA<DioException>()),
      );
      // Original attempt + exactly one replay. A loop here would hammer
      // the server with invalid credentials.
      expect(attempts, 2);
    });
  });
}

// -- Test helpers -------------------------------------------------------------

/// AuthService whose token endpoint always returns [token].
AuthService _authServiceReturning(String token) => AuthService(
      secureStorage: _registeredStorage(),
      baseUrl: 'https://api.test',
      dio: _dioWith(_FakeAdapter((_) => _tokenResponse(token: token))),
    );

_InMemorySecureStorage _registeredStorage() => _InMemorySecureStorage()
  ..values['ct_device_id'] = 'device-123'
  ..values['ct_device_secret'] = 'secret-abc';

Dio _dioWith(_FakeAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.test'));
  dio.httpClientAdapter = adapter;
  return dio;
}

ResponseBody _tokenResponse({String token = 'jwt-test'}) => _jsonResponse({
      'token': token,
      'expiresAt':
          DateTime.now().toUtc().add(const Duration(hours: 24)).toIso8601String(),
    });

ResponseBody _jsonResponse(Map<String, dynamic> body, {int statusCode = 200}) =>
    ResponseBody.fromString(
      jsonEncode(body),
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

/// In-memory SecureStorage — overrides every method that would otherwise
/// hit platform channels (unavailable in unit tests).
class _InMemorySecureStorage extends SecretStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> getDeviceId() async => values['ct_device_id'];

  @override
  Future<void> setDeviceId(String id) async => values['ct_device_id'] = id;

  @override
  Future<String?> getDeviceSecret() async => values['ct_device_secret'];

  @override
  Future<void> setDeviceSecret(String secret) async =>
      values['ct_device_secret'] = secret;
}

/// Programmable Dio adapter counting requests — the unit-test equivalent
/// of a fake HTTP server.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final ResponseBody Function(RequestOptions options) handler;
  int requestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestCount++;
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}
