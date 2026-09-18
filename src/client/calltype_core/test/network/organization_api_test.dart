import 'package:calltype_core/network/organization_dtos.dart';
import 'package:calltype_core/network/organization_api.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// Guards the error-code mapping used by the Organization settings screen
/// (E05 deliverable 5 — "error mapping (503/409/410)"). A misclassified
/// error means the UI would show the generic failure text instead of the
/// specific, actionable one (e.g. "org limit reached").
void main() {
  DioException dioError({required int status, Object? data}) {
    final options = RequestOptions(path: '/orgs');
    return DioException(
      requestOptions: options,
      response: Response(requestOptions: options, statusCode: status, data: data),
    );
  }

  test('503 maps to business_mode_disabled', () {
    expect(
      organizationErrorCode(dioError(status: 503)),
      OrgErrorCodes.businessModeDisabled,
    );
  });

  test('410 maps to invite_invalid', () {
    expect(
      organizationErrorCode(dioError(status: 410)),
      OrgErrorCodes.inviteInvalid,
    );
  });

  test('409 forwards the server-provided code', () {
    expect(
      organizationErrorCode(dioError(status: 409, data: {'code': 'last_admin'})),
      OrgErrorCodes.lastAdmin,
    );
    expect(
      organizationErrorCode(dioError(status: 409, data: {'code': 'org_limit'})),
      OrgErrorCodes.orgLimit,
    );
  });

  test('an unrelated error (e.g. 404) or a non-Dio error maps to null', () {
    expect(organizationErrorCode(dioError(status: 404)), isNull);
    expect(organizationErrorCode(StateError('boom')), isNull);
  });

  test('GroupBusinessInfo.none reports as not business', () {
    expect(GroupBusinessInfo.none.isBusiness, isFalse);
    expect(
      GroupBusinessInfo.fromJson({
        'organizationId': 'org1',
        'organizationName': 'Acme',
        'auditorDeviceId': 'dev1',
      }).isBusiness,
      isTrue,
    );
  });
}
