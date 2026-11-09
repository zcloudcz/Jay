import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:calltype_core/network/api_client.dart';

/// Smoke tests for [ApiClient] construction and method signatures.
///
/// Full HTTP-level testing of ApiClient would require either a mock Dio
/// adapter or a running backend server. These tests verify that the class
/// can be instantiated and that its public API surface is as expected —
/// catching compilation errors and constructor regressions early.
void main() {
  group('ApiClient', () {
    test('creates with base URL', () {
      // Verify the constructor accepts a base URL without throwing.
      final client = ApiClient(baseUrl: 'https://api.calltype.test');

      expect(client, isNotNull);
    });

    test('creates with custom Dio instance', () {
      // Allows injecting a pre-configured Dio (e.g., with interceptors,
      // test adapters, or custom timeouts).
      final dio = Dio(BaseOptions(
        baseUrl: 'https://custom.test',
        connectTimeout: const Duration(seconds: 5),
      ));
      final client = ApiClient(baseUrl: 'https://custom.test', dio: dio);

      expect(client, isNotNull);
    });

    test('public methods exist and accept expected parameters', () {
      // Compile-time verification that the public API surface matches
      // what callers (onboarding, contacts, calls) expect. This catches
      // accidental renames or signature changes.
      final client = ApiClient(baseUrl: 'https://api.calltype.test');

      // Verify method references are valid — we don't call them because
      // they would attempt real HTTP calls. The fact that these compile
      // is the assertion.
      expect(client.registerDevice, isA<Function>());
      expect(client.getKeyBundle, isA<Function>());
      expect(client.getTurnCredentials, isA<Function>());
      expect(client.registerAccount, isA<Function>());
      expect(client.login, isA<Function>());
    });

    test('getDeviceProfile asks GET /devices/{id}/profile', () async {
      // Spec 2026-11-09-contacts-from-replies C1: the id lookup, never the
      // key bundle (which would burn a one-time pre-key).
      final adapter = _ProfileAdapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://api.calltype.test'))
        ..httpClientAdapter = adapter;
      final client = ApiClient(baseUrl: 'https://api.calltype.test', dio: dio);

      final profile =
          await client.getDeviceProfile('a1b2c3d4-0000-4000-8000-000000000001');

      expect(adapter.requests.single.method, 'GET');
      expect(adapter.requests.single.path,
          '/devices/a1b2c3d4-0000-4000-8000-000000000001/profile');
      expect(profile['userHandle'], 'CT-ALIC-E234');
      expect(profile['isBot'], false);
    });
  });
}

class _ProfileAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode({
        'deviceId': 'a1b2c3d4-0000-4000-8000-000000000001',
        'userHandle': 'CT-ALIC-E234',
        'isBot': false,
        'displayName': null,
      }),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
