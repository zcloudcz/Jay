/// DTOs for the account TOTP MFA endpoints (N03a/N03c). Shapes copied from
/// `MfaEndpoints.cs` — see the record types at the bottom of that file.
class MfaStatus {
  const MfaStatus({
    required this.enabled,
    required this.confirmedAt,
    required this.backupCodesRemaining,
  });

  factory MfaStatus.fromJson(Map<String, dynamic> json) => MfaStatus(
    enabled: json['enabled'] as bool,
    confirmedAt: json['confirmedAt'] == null
        ? null
        : DateTime.parse(json['confirmedAt'] as String),
    backupCodesRemaining: json['backupCodesRemaining'] as int,
  );

  final bool enabled;
  final DateTime? confirmedAt;
  final int backupCodesRemaining;
}

class MfaEnrollment {
  const MfaEnrollment({required this.secretBase32, required this.otpauthUri});

  factory MfaEnrollment.fromJson(Map<String, dynamic> json) => MfaEnrollment(
    secretBase32: json['secretBase32'] as String,
    otpauthUri: json['otpauthUri'] as String,
  );

  final String secretBase32;
  final String otpauthUri;
}

class MfaVerification {
  const MfaVerification({required this.token, required this.expiresAt});

  factory MfaVerification.fromJson(Map<String, dynamic> json) =>
      MfaVerification(
        token: json['token'] as String,
        expiresAt: DateTime.parse(json['expiresAt'] as String),
      );

  /// The short-lived step-up token (`amr=totp`) — see [StepUpToken].
  final String token;
  final DateTime expiresAt;
}

/// Well-known MFA error codes the server sends in a JSON `code` field (see
/// `MfaEndpoints.cs`: `NotConfigured`/`AlreadyEnabled`/`NotEnabled`/
/// `InvalidCode`/`Locked`) plus `mfa_required` from [MfaAuthHelper] on the
/// gated org/emergency endpoints.
abstract final class MfaErrorCodes {
  static const required = 'mfa_required';
  static const invalidCode = 'mfa_invalid_code';
  static const codeReused = 'mfa_code_reused';
  static const locked = 'mfa_locked';
  static const notEnabled = 'mfa_not_enabled';
  static const alreadyEnabled = 'mfa_already_enabled';
  static const notConfigured = 'mfa_not_configured';
}
