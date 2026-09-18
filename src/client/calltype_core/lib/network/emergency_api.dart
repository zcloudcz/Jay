import 'package:dio/dio.dart';

import 'api_client.dart';
import 'emergency_dtos.dart';

/// REST client extension for the E07 emergency channel (kits, offline
/// enrollment, drills, proof export). See
/// `docs/superpowers/plans/2026-09-18-business-mode-contracts.md` (E07) for
/// the endpoint shapes this codes against.
extension EmergencyApi on ApiClient {
  /// POST /orgs/{id}/emergency/kits {label, count} — codes are returned ONCE.
  Future<IssuedEmergencyKit> issueEmergencyKit(
    String organizationId, {
    required String label,
    required int count,
  }) async {
    final response = await transport.post<Map<String, dynamic>>(
      '/orgs/$organizationId/emergency/kits',
      data: {'label': label, 'count': count},
    );
    return IssuedEmergencyKit.fromJson(response.data!);
  }

  /// GET /orgs/{id}/emergency/kits
  Future<List<EmergencyKitInfo>> getEmergencyKits(
    String organizationId,
  ) async {
    final response = await transport.get<List<dynamic>>(
      '/orgs/$organizationId/emergency/kits',
    );
    return response.data!
        .cast<Map<String, dynamic>>()
        .map(EmergencyKitInfo.fromJson)
        .toList();
  }

  /// DELETE /orgs/{id}/emergency/kits/{kitId}
  Future<void> revokeEmergencyKit(String organizationId, String kitId) =>
      transport.delete<void>('/orgs/$organizationId/emergency/kits/$kitId');

  /// POST /orgs/emergency/enroll {code} → {organizationId}. Any authenticated
  /// device, no account or prior enrollment required (spec 2.3).
  Future<String> enrollWithEmergencyCode(String code) async {
    final response = await transport.post<Map<String, dynamic>>(
      '/orgs/emergency/enroll',
      data: {'code': code},
    );
    return response.data!['organizationId'] as String;
  }

  /// POST /orgs/{id}/emergency/drills → {drillId}.
  Future<int> startEmergencyDrill(String organizationId) async {
    final response = await transport.post<Map<String, dynamic>>(
      '/orgs/$organizationId/emergency/drills',
    );
    return response.data!['drillId'] as int;
  }

  /// POST /orgs/{id}/emergency/drills/{drillId}/confirm — any device that is
  /// a member of the emergency conversation.
  Future<void> confirmEmergencyDrill(String organizationId, int drillId) =>
      transport.post<void>(
        '/orgs/$organizationId/emergency/drills/$drillId/confirm',
      );

  /// POST /orgs/{id}/emergency/drills/{drillId}/complete
  Future<void> completeEmergencyDrill(String organizationId, int drillId) =>
      transport.post<void>(
        '/orgs/$organizationId/emergency/drills/$drillId/complete',
      );

  /// GET /orgs/{id}/emergency/drills
  Future<List<EmergencyDrillInfo>> getEmergencyDrills(
    String organizationId,
  ) async {
    final response = await transport.get<List<dynamic>>(
      '/orgs/$organizationId/emergency/drills',
    );
    return response.data!
        .cast<Map<String, dynamic>>()
        .map(EmergencyDrillInfo.fromJson)
        .toList();
  }

  /// GET /orgs/{id}/emergency/proof?format=json|txt — returns the raw bytes
  /// so the caller can hand them straight to the file-save mechanism, same
  /// convention as [OrganizationApi.exportAdminAudit].
  Future<List<int>> exportEmergencyProof(
    String organizationId, {
    String format = 'txt',
  }) async {
    final response = await transport.get<List<int>>(
      '/orgs/$organizationId/emergency/proof',
      queryParameters: {'format': format},
      options: Options(responseType: ResponseType.bytes),
    );
    return response.data!;
  }
}

/// Maps a failed emergency-API call to one of [EmergencyErrorCodes], or null
/// when it isn't one of the documented codes (caller falls back to a generic
/// failure message). Mirrors `organizationErrorCode`.
String? emergencyErrorCode(Object error) {
  if (error is! DioException) return null;
  final status = error.response?.statusCode;
  if (status == 503) return EmergencyErrorCodes.businessModeDisabled;
  if (status == 410 || status == 409) {
    final body = error.response?.data;
    if (body is Map && body['code'] is String) return body['code'] as String;
  }
  return null;
}
