import 'package:dio/dio.dart';

import 'api_client.dart';
import 'organization_dtos.dart';

/// REST client extension for Jay Business mode (organizations, invites,
/// admin audit). See `docs/superpowers/plans/2026-09-18-business-mode-contracts.md`
/// (E01) for the endpoint shapes this codes against.
extension OrganizationApi on ApiClient {
  /// POST /orgs {name} — requires a registered account.
  Future<OrganizationInfo> createOrganization(String name) async {
    final response = await transport.post<Map<String, dynamic>>(
      '/orgs',
      data: {'name': name},
    );
    return OrganizationInfo.fromJson(response.data!);
  }

  /// GET /orgs/mine — organizations the current account belongs to.
  Future<List<OrganizationInfo>> getMyOrganizations() async {
    final response = await transport.get<List<dynamic>>('/orgs/mine');
    return response.data!
        .cast<Map<String, dynamic>>()
        .map(OrganizationInfo.fromJson)
        .toList();
  }

  /// GET /orgs/{id}
  Future<OrganizationInfo> getOrganization(String organizationId) async {
    final response = await transport.get<Map<String, dynamic>>(
      '/orgs/$organizationId',
    );
    return OrganizationInfo.fromJson(response.data!);
  }

  /// PATCH /orgs/{id} — currently only the name is client-editable.
  Future<OrganizationInfo> updateOrganization(
    String organizationId, {
    String? name,
  }) async {
    final response = await transport.patch<Map<String, dynamic>>(
      '/orgs/$organizationId',
      data: {'name': ?name},
    );
    return OrganizationInfo.fromJson(response.data!);
  }

  /// GET members list for an organization (used by the admin screen and by
  /// the "who can I add to a business group" picker).
  Future<List<OrgMemberInfo>> getOrganizationMembers(
    String organizationId,
  ) async {
    final response = await transport.get<List<dynamic>>(
      '/orgs/$organizationId/members',
    );
    return response.data!
        .cast<Map<String, dynamic>>()
        .map(OrgMemberInfo.fromJson)
        .toList();
  }

  /// PUT /orgs/{id}/members/{accountId} {role} — set/promote a member's role.
  Future<void> setOrganizationMemberRole(
    String organizationId,
    String accountId,
    String role,
  ) => transport.put<void>(
    '/orgs/$organizationId/members/$accountId',
    data: {'role': role},
  );

  /// DELETE /orgs/{id}/members/{accountId} — 409 `last_admin` if this would
  /// remove the last admin.
  Future<void> removeOrganizationMember(
    String organizationId,
    String accountId,
  ) => transport.delete<void>('/orgs/$organizationId/members/$accountId');

  /// POST /orgs/{id}/invites → {code, expiresAt}.
  Future<OrgInviteInfo> createInvite(String organizationId) async {
    final response = await transport.post<Map<String, dynamic>>(
      '/orgs/$organizationId/invites',
    );
    return OrgInviteInfo.fromJson(response.data!);
  }

  /// POST /orgs/enroll {code} → {organizationId}. This is how a device joins
  /// an organization — 410 `invite_invalid` when the code is used/expired.
  Future<String> enrollWithInvite(String code) async {
    final response = await transport.post<Map<String, dynamic>>(
      '/orgs/enroll',
      data: {'code': code},
    );
    return response.data!['organizationId'] as String;
  }

  /// DELETE /orgs/{id}/enrollments/{deviceId} — admin revokes a device.
  Future<void> revokeEnrollment(String organizationId, String deviceId) =>
      transport.delete<void>('/orgs/$organizationId/enrollments/$deviceId');

  /// PUT /orgs/{id}/auditor {deviceId} — sets the archiver bot's device id.
  /// The id itself comes from out-of-band archiver provisioning, not from
  /// anything the client can discover — hence the plain text field in the UI.
  Future<void> setAuditorDevice(String organizationId, String deviceId) =>
      transport.put<void>(
        '/orgs/$organizationId/auditor',
        data: {'deviceId': deviceId},
      );

  /// GET /orgs/{id}/admin-audit?format=json|csv — returns the raw bytes so
  /// the caller can hand them straight to the file-save mechanism.
  Future<List<int>> exportAdminAudit(
    String organizationId, {
    String format = 'csv',
  }) async {
    final response = await transport.get<List<int>>(
      '/orgs/$organizationId/admin-audit',
      queryParameters: {'format': format},
      options: Options(responseType: ResponseType.bytes),
    );
    return response.data!;
  }

  /// GET /orgs/{id}/audit/records/count — used as the "archive active"
  /// signal for admins (a non-zero count proves records are landing).
  Future<int> getAuditRecordCount(String organizationId) async {
    final response = await transport.get<Map<String, dynamic>>(
      '/orgs/$organizationId/audit/records/count',
    );
    return response.data!['count'] as int;
  }

  /// GET /groups/{id} — group detail including business metadata. Anonymous
  /// groups (no `organizationId` in the response) map to
  /// [GroupBusinessInfo.none]. A 404/format-mismatch is swallowed to `none`
  /// so an anonymous conversation never breaks on this lookup (E02 owns the
  /// exact endpoint shape; this is E05's assumed contract — see the E05
  /// final report for the deviation this must reconcile with B00).
  Future<GroupBusinessInfo> getGroupBusinessInfo(String groupId) async {
    try {
      final response = await transport.get<Map<String, dynamic>>(
        '/groups/$groupId',
      );
      return GroupBusinessInfo.fromJson(response.data!);
    } on DioException {
      return GroupBusinessInfo.none;
    }
  }
}

/// Maps a failed organization-API call to one of [OrgErrorCodes], or null
/// when it isn't one of the documented business-mode errors (caller should
/// fall back to a generic failure message in that case).
String? organizationErrorCode(Object error) {
  if (error is! DioException) return null;
  final status = error.response?.statusCode;
  if (status == 503) return OrgErrorCodes.businessModeDisabled;
  if (status == 410) return OrgErrorCodes.inviteInvalid;
  if (status == 409) {
    final body = error.response?.data;
    if (body is Map && body['code'] is String) return body['code'] as String;
  }
  return null;
}
