/// DTOs and JSON mapping for the Business mode / organization API.
///
/// Kept separate from `organization_api.dart` so the wire-format details
/// (field names, error codes) live in one place, mirroring how
/// `channel_dtos.dart` is split from `api_client.dart`.
library;

/// A registered organization the current account belongs to.
class OrganizationInfo {
  const OrganizationInfo({
    required this.organizationId,
    required this.name,
    required this.role,
    required this.archiveLevel,
    required this.auditorDeviceId,
  });

  final String organizationId;
  final String name;
  /// One of `owner`, `orgAdmin`, `auditorApprover`, `member` (server's
  /// `OrgRole`, camelCased on the wire).
  final String role;
  /// `metadata` or `full` (server's `ArchiveLevel`).
  final String archiveLevel;
  final String? auditorDeviceId;

  bool get isAdmin => role == 'owner' || role == 'orgAdmin';

  factory OrganizationInfo.fromJson(Map<String, dynamic> json) =>
      OrganizationInfo(
        organizationId: json['organizationId'] as String,
        name: json['name'] as String,
        role: json['role'] as String,
        archiveLevel: json['archiveLevel'] as String? ?? 'metadata',
        auditorDeviceId: json['auditorDeviceId'] as String?,
      );
}

class OrgMemberInfo {
  const OrgMemberInfo({required this.accountId, required this.role});
  final String accountId;
  final String role;

  factory OrgMemberInfo.fromJson(Map<String, dynamic> json) =>
      OrgMemberInfo(
        accountId: json['accountId'] as String,
        role: json['role'] as String,
      );
}

class OrgInviteInfo {
  const OrgInviteInfo({required this.code, required this.expiresAt});
  final String code;
  final String expiresAt;

  factory OrgInviteInfo.fromJson(Map<String, dynamic> json) => OrgInviteInfo(
    code: json['code'] as String,
    expiresAt: json['expiresAt'] as String,
  );
}

/// Business-conversation metadata for one group, used to render the
/// permanent archive banner and the auditor's member-list tile.
///
/// `null` fields mean "not a business conversation" — the caller treats a
/// null [organizationId] as the anonymous case (KB1: nothing shown).
class GroupBusinessInfo {
  const GroupBusinessInfo({
    required this.organizationId,
    required this.organizationName,
    required this.auditorDeviceId,
  });

  final String? organizationId;
  final String? organizationName;
  final String? auditorDeviceId;

  bool get isBusiness => organizationId != null;

  factory GroupBusinessInfo.fromJson(Map<String, dynamic> json) =>
      GroupBusinessInfo(
        organizationId: json['organizationId'] as String?,
        organizationName: json['organizationName'] as String?,
        auditorDeviceId: json['auditorDeviceId'] as String?,
      );

  static const none = GroupBusinessInfo(
    organizationId: null,
    organizationName: null,
    auditorDeviceId: null,
  );
}

/// Known `code` values the server returns in a 409 body, plus the two
/// distinguished statuses (503 disabled, 410 expired invite) mapped to
/// synthetic codes so callers can `switch` on one string everywhere.
abstract final class OrgErrorCodes {
  static const businessModeDisabled = 'business_mode_disabled';
  static const auditorNotConfigured = 'auditor_not_configured';
  static const auditorImmutable = 'auditor_immutable';
  static const lastAdmin = 'last_admin';
  static const orgLimit = 'org_limit';
  static const inviteInvalid = 'invite_invalid';
  static const auditRecipientMissing = 'audit_recipient_missing';
}
