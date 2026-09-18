import 'dart:convert';
import 'dart:typed_data';

import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/network/emergency_dtos.dart';
import 'package:calltype_core/network/emergency_api.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// Minimal fake transport that replays a fixed response, same pattern as
/// organization_api_contract_test.dart's `_FakeServer`.
class _FakeServer implements HttpClientAdapter {
  _FakeServer(this.status, this.body);

  final int status;
  final Object? body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
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

/// Guards the E07 emergency-channel error-code mapping, mirroring
/// organization_api_test.dart's coverage of organizationErrorCode.
void main() {
  DioException dioError({required int status, Object? data}) {
    final options = RequestOptions(path: '/orgs/emergency/enroll');
    return DioException(
      requestOptions: options,
      response: Response(requestOptions: options, statusCode: status, data: data),
    );
  }

  test('503 maps to business_mode_disabled', () {
    expect(
      emergencyErrorCode(dioError(status: 503)),
      EmergencyErrorCodes.businessModeDisabled,
    );
  });

  test('410 forwards the server-provided code (used/revoked/invalid code)', () {
    expect(
      emergencyErrorCode(dioError(status: 410, data: {'code': 'emergency_code_used'})),
      EmergencyErrorCodes.emergencyCodeUsed,
    );
    expect(
      emergencyErrorCode(dioError(status: 410, data: {'code': 'kit_revoked'})),
      EmergencyErrorCodes.kitRevoked,
    );
    expect(
      emergencyErrorCode(dioError(status: 410, data: {'code': 'emergency_code_invalid'})),
      EmergencyErrorCodes.emergencyCodeInvalid,
    );
  });

  test('409 forwards the server-provided code', () {
    expect(
      emergencyErrorCode(dioError(status: 409, data: {'code': 'auditor_not_configured'})),
      EmergencyErrorCodes.auditorNotConfigured,
    );
  });

  test('unmapped error returns null', () {
    expect(emergencyErrorCode(dioError(status: 500)), isNull);
    expect(emergencyErrorCode(Exception('boom')), isNull);
  });

  test('IssuedEmergencyKit.fromJson parses codes and printable payload', () {
    final kit = IssuedEmergencyKit.fromJson({
      'kitId': 'kit-1',
      'label': 'HQ incident team',
      'issuedAt': '2026-09-18T00:00:00Z',
      'recoveryCode': 'RECOVERY-CODE',
      'codes': ['CODE-1', 'CODE-2'],
      'printable': 'CallType — Emergency channel enrollment kit',
    });

    expect(kit.codes, ['CODE-1', 'CODE-2']);
    expect(kit.recoveryCode, 'RECOVERY-CODE');
  });

  test('EmergencyKitInfo.isRevoked reflects revokedAt', () {
    final active = EmergencyKitInfo.fromJson({
      'kitId': 'k1', 'label': 'A', 'issuedAt': 'now',
      'revokedAt': null, 'codesTotal': 5, 'codesRemaining': 3,
    });
    final revoked = EmergencyKitInfo.fromJson({
      'kitId': 'k2', 'label': 'B', 'issuedAt': 'now',
      'revokedAt': 'now', 'codesTotal': 5, 'codesRemaining': 5,
    });

    expect(active.isRevoked, isFalse);
    expect(revoked.isRevoked, isTrue);
  });

  test('enrollWithEmergencyCode replays the real 200 {organizationId, groupId} shape', () async {
    final server = _FakeServer(200, {
      'organizationId': 'org-1',
      'groupId': 'group-1',
    });
    final dio = Dio(BaseOptions(baseUrl: 'http://test'))
      ..httpClientAdapter = server;
    final api = ApiClient(baseUrl: 'http://test', dio: dio);

    final result = await api.enrollWithEmergencyCode('CODE-1');

    expect(result.organizationId, 'org-1');
    expect(result.groupId, 'group-1');
  });

  test('EmergencyEnrollmentResult.fromJson copes with a null groupId', () {
    final result = EmergencyEnrollmentResult.fromJson({
      'organizationId': 'org-1',
      'groupId': null,
    });

    expect(result.groupId, isNull);
  });

  test('EmergencyDrillInfo.isComplete reflects completedAt', () {
    final drill = EmergencyDrillInfo.fromJson({
      'drillId': 1, 'startedAt': 'now', 'completedAt': 'now',
      'confirmedMemberCount': 4, 'responseTimeSeconds': 12.5,
    });

    expect(drill.isComplete, isTrue);
    expect(drill.responseTimeSeconds, 12.5);
  });
}
