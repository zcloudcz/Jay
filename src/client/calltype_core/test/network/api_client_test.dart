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
  });
}
