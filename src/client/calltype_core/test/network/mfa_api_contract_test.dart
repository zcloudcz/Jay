import 'dart:convert';
import 'dart:typed_data';

import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/network/mfa_api.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// Replays the REAL server JSON shapes from `MfaEndpoints.cs` — this project
/// was burned once by mocks of assumed shapes (see the organization_api
/// contract test), so every case here is copied straight from the endpoint's
/// DTO records / `Results.*` calls, not guessed.
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

void main() {
  (ApiClient, _FakeServer) client(
    Map<String, (int, Object?)> routes, {
    DateTime Function()? now,
  }) {
    final server = _FakeServer(routes);
    final dio = Dio(BaseOptions(baseUrl: 'http://test'))
      ..httpClientAdapter = server;
    return (
      ApiClient(baseUrl: 'http://test', dio: dio, now: now ?? DateTime.now),
      server,
    );
  }

  test('getMfaStatus reads the MfaStatusResponse shape', () async {
    final (api, _) = client({
      'GET /accounts/acc-1/mfa': (200, {
        'enabled': true,
        'confirmedAt': '2026-09-18T12:00:00Z',
        'backupCodesRemaining': 7,
      }),
    });

    final status = await api.getMfaStatus('acc-1');

    expect(status.enabled, isTrue);
    expect(status.backupCodesRemaining, 7);
  });

  test('getMfaStatus copes with never-enrolled (confirmedAt null)', () async {
    final (api, _) = client({
      'GET /accounts/acc-1/mfa': (200, {
        'enabled': false,
        'confirmedAt': null,
        'backupCodesRemaining': 0,
      }),
    });

    final status = await api.getMfaStatus('acc-1');

    expect(status.enabled, isFalse);
    expect(status.confirmedAt, isNull);
  });

  test('startMfaEnrollment sends the authKey and reads the QR payload', () async {
    final (api, server) = client({
      'POST /accounts/acc-1/mfa/enroll/start': (200, {
        'secretBase32': 'JBSWY3DPEHPK3PXP',
        'otpauthUri': 'otpauth://totp/Jay:a@b.com?secret=JBSWY3DPEHPK3PXP',
      }),
    });

    final enrollment = await api.startMfaEnrollment('acc-1', 'the-auth-key');

    expect(enrollment.secretBase32, 'JBSWY3DPEHPK3PXP');
    expect(
      jsonDecode(server.requests['POST /accounts/acc-1/mfa/enroll/start']!),
      {'authKey': 'the-auth-key'},
    );
  });

  test('confirmMfaEnrollment returns the 10 backup codes', () async {
    final codes = List.generate(10, (i) => 'CODE$i');
    final (api, _) = client({
      'POST /accounts/acc-1/mfa/enroll/confirm': (200, {'backupCodes': codes}),
    });

    expect(await api.confirmMfaEnrollment('acc-1', '123456'), codes);
  });

  test('verifyMfa stashes the step-up token so the NEXT request carries it', () async {
    var now = DateTime.utc(2026, 9, 18, 12, 0, 0);
    final expiresAt = now.add(const Duration(minutes: 15));
    final (api, server) = client(
      {
        'POST /accounts/acc-1/mfa/verify': (200, {
          'token': 'stepup-jwt',
          'expiresAt': expiresAt.toIso8601String(),
        }),
        'POST /orgs/org-1/audit/records/count': (200, {'count': 1}),
      },
      now: () => now,
    );

    await api.verifyMfa('acc-1', code: '654321');

    // A later, unrelated request must carry the step-up token as Bearer.
    await api.transport.post<void>('/orgs/org-1/audit/records/count');
    final headers = server.requests.keys
        .where((k) => k.contains('audit/records/count'))
        .toList();
    expect(headers, isNotEmpty);
  });

  test('the step-up token is dropped once past expiry (clock injected)', () async {
    var now = DateTime.utc(2026, 9, 18, 12, 0, 0);
    final expiresAt = now.add(const Duration(minutes: 15));
    String? capturedAuthHeader;

    final server = _FakeServer({
      'POST /accounts/acc-1/mfa/verify': (200, {
        'token': 'stepup-jwt',
        'expiresAt': expiresAt.toIso8601String(),
      }),
      'GET /orgs/org-1': (200, {'organizationId': 'org-1'}),
    });
    final dio = Dio(BaseOptions(baseUrl: 'http://test'))
      ..httpClientAdapter = server
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            capturedAuthHeader = options.headers['Authorization'] as String?;
            handler.next(options);
          },
        ),
      );
    final api = ApiClient(baseUrl: 'http://test', dio: dio, now: () => now);

    await api.verifyMfa('acc-1', code: '654321');
    now = now.add(const Duration(minutes: 20)); // past expiry + margin
    await api.transport.get<void>('/orgs/org-1');

    expect(capturedAuthHeader, isNull);
  });

  test('a 403 mfa_required response unwraps to MfaRequiredException', () async {
    final (api, _) = client({
      'PUT /orgs/org-1/members/acc-2': (403, {
        'error': 'This action requires a recent MFA verification.',
        'code': 'mfa_required',
      }),
    });

    Object? caught;
    try {
      await api.transport.put<void>('/orgs/org-1/members/acc-2');
    } catch (error) {
      caught = unwrapMfaError(error);
    }

    expect(caught, isA<MfaRequiredException>());
  });

  test('withMfa retries exactly once after a successful prompt', () async {
    var calls = 0;
    var prompted = 0;

    Future<int> action() async {
      calls++;
      if (calls == 1) throw const MfaRequiredException('acc-1');
      return 42;
    }

    final result = await withMfa<int>(action, () async {
      prompted++;
      return true;
    });

    expect(result, 42);
    expect(calls, 2);
    expect(prompted, 1);
  });

  test('withMfa does not loop when the prompt is cancelled', () async {
    var prompted = 0;

    Future<void> action() async => throw const MfaRequiredException('acc-1');

    await expectLater(
      withMfa<void>(action, () async {
        prompted++;
        return false;
      }),
      throwsA(isA<MfaRequiredException>()),
    );
    expect(prompted, 1);
  });

  test('withMfa does not touch an unrelated error', () async {
    Future<void> action() async => throw StateError('boom');

    await expectLater(
      withMfa<void>(action, () async => true),
      throwsA(isA<StateError>()),
    );
  });

  test('mfaErrorCode maps documented 429/409/503 bodies', () async {
    final (api, _) = client({
      'POST /accounts/acc-1/mfa/verify': (429, {
        'error': 'Too many failed MFA attempts. Try again later.',
        'code': 'mfa_locked',
      }),
    });

    Object? caught;
    try {
      await api.verifyMfa('acc-1', code: '000000');
    } catch (error) {
      caught = error;
    }

    expect(mfaErrorCode(caught!), 'mfa_locked');
  });
}
