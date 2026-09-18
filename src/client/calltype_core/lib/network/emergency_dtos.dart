/// DTOs and JSON mapping for the E07 emergency-channel API. Mirrors
/// `organization_dtos.dart`'s split from its `_api.dart` file.
library;

/// Response of `POST /orgs/{id}/emergency/kits` — the ONLY place the
/// plaintext codes and recovery code are ever available. Never persisted by
/// the server, and the client must not persist it either (show once, let the
/// admin copy/share, then discard).
class IssuedEmergencyKit {
  const IssuedEmergencyKit({
    required this.kitId,
    required this.label,
    required this.issuedAt,
    required this.recoveryCode,
    required this.codes,
    required this.printable,
  });

  final String kitId;
  final String label;
  final String issuedAt;
  final String recoveryCode;
  final List<String> codes;
  final String printable;

  factory IssuedEmergencyKit.fromJson(Map<String, dynamic> json) =>
      IssuedEmergencyKit(
        kitId: json['kitId'] as String,
        label: json['label'] as String,
        issuedAt: json['issuedAt'] as String,
        recoveryCode: json['recoveryCode'] as String,
        codes: (json['codes'] as List<dynamic>).cast<String>(),
        printable: json['printable'] as String,
      );
}

/// Result of `POST /orgs/emergency/enroll` — `groupId` is what lets the
/// client open the emergency conversation directly instead of the chat list
/// (docs/acceptance/business-mode.md, "Známé limity"). Nullable because the
/// server can still return it as `null` in the pre-existing edge case where
/// the org has no auditor configured yet.
class EmergencyEnrollmentResult {
  const EmergencyEnrollmentResult({
    required this.organizationId,
    required this.groupId,
  });

  final String organizationId;
  final String? groupId;

  factory EmergencyEnrollmentResult.fromJson(Map<String, dynamic> json) =>
      EmergencyEnrollmentResult(
        organizationId: json['organizationId'] as String,
        groupId: json['groupId'] as String?,
      );
}

/// One row of `GET /orgs/{id}/emergency/kits` — counts only, never codes.
class EmergencyKitInfo {
  const EmergencyKitInfo({
    required this.kitId,
    required this.label,
    required this.issuedAt,
    required this.revokedAt,
    required this.codesTotal,
    required this.codesRemaining,
  });

  final String kitId;
  final String label;
  final String issuedAt;
  final String? revokedAt;
  final int codesTotal;
  final int codesRemaining;

  bool get isRevoked => revokedAt != null;

  factory EmergencyKitInfo.fromJson(Map<String, dynamic> json) =>
      EmergencyKitInfo(
        kitId: json['kitId'] as String,
        label: json['label'] as String,
        issuedAt: json['issuedAt'] as String,
        revokedAt: json['revokedAt'] as String?,
        codesTotal: json['codesTotal'] as int,
        codesRemaining: json['codesRemaining'] as int,
      );
}

/// One row of `GET /orgs/{id}/emergency/drills`.
class EmergencyDrillInfo {
  const EmergencyDrillInfo({
    required this.drillId,
    required this.startedAt,
    required this.completedAt,
    required this.confirmedMemberCount,
    required this.responseTimeSeconds,
  });

  final int drillId;
  final String startedAt;
  final String? completedAt;
  final int confirmedMemberCount;
  final double? responseTimeSeconds;

  bool get isComplete => completedAt != null;

  factory EmergencyDrillInfo.fromJson(Map<String, dynamic> json) =>
      EmergencyDrillInfo(
        drillId: json['drillId'] as int,
        startedAt: json['startedAt'] as String,
        completedAt: json['completedAt'] as String?,
        confirmedMemberCount: json['confirmedMemberCount'] as int,
        responseTimeSeconds: (json['responseTimeSeconds'] as num?)
            ?.toDouble(),
      );
}

/// Known `code` values from a failed emergency-API call's 409/410 body, for
/// the same one-string-switch pattern as [OrgErrorCodes].
abstract final class EmergencyErrorCodes {
  static const businessModeDisabled = 'business_mode_disabled';
  static const auditorNotConfigured = 'auditor_not_configured';
  static const kitRevoked = 'kit_revoked';
  static const emergencyCodeUsed = 'emergency_code_used';
  static const emergencyCodeInvalid = 'emergency_code_invalid';
  static const invalidCount = 'invalid_count';
  static const invalidLabel = 'invalid_label';
}
