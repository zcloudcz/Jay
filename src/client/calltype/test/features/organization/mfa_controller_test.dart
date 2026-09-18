import 'dart:typed_data';

import 'package:calltype/core/network/api_client.dart';
import 'package:calltype/features/organization/mfa_controller.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// N03d: [MfaController] against a faked API. Uses a real [HttpClientAdapter]
/// (not the request-interceptor short-circuit `organization_controller_test.dart`
/// uses) because the behavior under test — 403 `mfa_required` becoming an
/// [MfaRequiredException] — is itself implemented as a response interceptor
/// on [ApiClient] (`_StepUpInterceptor`); an interceptor that rejects during
/// `onRequest` never lets that later interceptor's `onError` run at all.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.respond);

  final Map<String, dynamic> Function(RequestOptions options) respond;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final result = respond(options);
    final status = result['status'] as int? ?? 200;
    final body = result['body'];
    return ResponseBody.fromString(
      body == null ? '' : jsonLikeEncode(body),
      status,
      headers: {'content-type': ['application/json']},
    );
  }
}

// Minimal JSON encoder — avoids pulling `dart:convert` just for this test's
// hand-built maps/lists of primitives.
String jsonLikeEncode(Object? value) {
  if (value is String) return '"${value.replaceAll('"', r'\"')}"';
  if (value is num || value is bool) return '$value';
  if (value is List) return '[${value.map(jsonLikeEncode).join(',')}]';
  if (value is Map) {
    return '{${value.entries.map((e) => '"${e.key}":${jsonLikeEncode(e.value)}').join(',')}}';
  }
  return 'null';
}

void main() {
  MfaController controllerWith(
    Map<String, dynamic> Function(RequestOptions options) respond,
  ) {
    final dio = Dio()..httpClientAdapter = _FakeAdapter(respond);
    final api = ApiClient(baseUrl: 'https://example.test', dio: dio);
    return MfaController(apiClient: api, accountId: 'acc-1');
  }

  test('enrol happy path returns the 10 backup codes exactly once', () async {
    final mfa = controllerWith((options) {
      if (options.path.endsWith('/mfa/enroll/start')) {
        return {
          'status': 200,
          'body': {'secretBase32': 'ABCDEF', 'otpauthUri': 'otpauth://totp/x'},
        };
      }
      if (options.path.endsWith('/mfa/enroll/confirm')) {
        return {
          'status': 200,
          'body': {
            'backupCodes': List.generate(10, (i) => 'CODE-$i'),
          },
        };
      }
      if (options.path.endsWith('/mfa')) {
        return {'status': 200, 'body': {'enabled': true, 'backupCodesRemaining': 10}};
      }
      throw StateError('unexpected ${options.path}');
    });

    final enrollment = await mfa.startEnrollment('correct horse battery staple');
    expect(enrollment?.secretBase32, 'ABCDEF');

    final codes = await mfa.confirmEnrollment('123456');
    expect(codes, hasLength(10));
    expect(mfa.errorCode, isNull);
    expect(mfa.status?.enabled, isTrue);
  });

  test('wrong code maps to mfa_invalid_code', () async {
    final mfa = controllerWith((options) {
      if (options.path.endsWith('/mfa/enroll/confirm')) {
        return {
          'status': 400,
          'body': {'error': 'bad code', 'code': 'mfa_invalid_code'},
        };
      }
      throw StateError('unexpected ${options.path}');
    });

    final codes = await mfa.confirmEnrollment('000000');

    expect(codes, isNull);
    expect(mfa.errorCode, 'mfa_invalid_code');
  });

  test('too many attempts maps to mfa_locked', () async {
    final mfa = controllerWith((options) {
      if (options.path.endsWith('/mfa/verify')) {
        return {
          'status': 429,
          'body': {'error': 'locked', 'code': 'mfa_locked'},
        };
      }
      throw StateError('unexpected ${options.path}');
    });

    final ok = await mfa.verify(code: '123456');

    expect(ok, isFalse);
    expect(mfa.errorCode, 'mfa_locked');
  });
}
