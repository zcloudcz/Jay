import 'package:dio/dio.dart';

import 'api_client.dart';
import 'mfa_dtos.dart';

/// REST client extension for account TOTP MFA (N03a/N03c). Shapes copied from
/// `MfaEndpoints.cs` — see that file's DTO records for the ground truth.
extension MfaApi on ApiClient {
  /// GET /accounts/{id}/mfa
  Future<MfaStatus> getMfaStatus(String accountId) async {
    final response = await transport.get<Map<String, dynamic>>(
      '/accounts/$accountId/mfa',
    );
    return MfaStatus.fromJson(response.data!);
  }

  /// POST /accounts/{id}/mfa/enroll/start {authKey} → {secretBase32, otpauthUri}.
  /// 403 without a valid account auth key, 429 `mfa_locked` while locked.
  Future<MfaEnrollment> startMfaEnrollment(
    String accountId,
    String authKey,
  ) async {
    final response = await transport.post<Map<String, dynamic>>(
      '/accounts/$accountId/mfa/enroll/start',
      data: {'authKey': authKey},
    );
    return MfaEnrollment.fromJson(response.data!);
  }

  /// POST /accounts/{id}/mfa/enroll/confirm {code} → the 10 backup codes.
  /// Shares verify's lockout; 409 `mfa_code_reused` if the step was already
  /// used by a previous verify/confirm.
  Future<List<String>> confirmMfaEnrollment(
    String accountId,
    String code,
  ) async {
    final response = await transport.post<Map<String, dynamic>>(
      '/accounts/$accountId/mfa/enroll/confirm',
      data: {'code': code},
    );
    return (response.data!['backupCodes'] as List<dynamic>).cast<String>();
  }

  /// POST /accounts/{id}/mfa/verify {code|backupCode} → step-up token.
  ///
  /// On success the token is stashed on this [ApiClient] via [setStepUpToken]
  /// so every subsequent request carries it as Bearer until it expires —
  /// callers do not need to do that themselves.
  Future<MfaVerification> verifyMfa(
    String accountId, {
    String? code,
    String? backupCode,
  }) async {
    final response = await transport.post<Map<String, dynamic>>(
      '/accounts/$accountId/mfa/verify',
      data: {'code': code, 'backupCode': backupCode},
    );
    final result = MfaVerification.fromJson(response.data!);
    setStepUpToken(result.token, result.expiresAt);
    return result;
  }

  /// POST /accounts/{id}/mfa/backup-codes/regenerate — requires a step-up
  /// token (the interceptor attaches the one [verifyMfa] stashed, if any).
  Future<List<String>> regenerateMfaBackupCodes(String accountId) async {
    final response = await transport.post<Map<String, dynamic>>(
      '/accounts/$accountId/mfa/backup-codes/regenerate',
    );
    return (response.data!['backupCodes'] as List<dynamic>).cast<String>();
  }

  /// POST /accounts/{id}/mfa/disable {code} → 204.
  Future<void> disableMfa(String accountId, String code) =>
      transport.post<void>(
        '/accounts/$accountId/mfa/disable',
        data: {'code': code},
      );
}

/// Thrown when a request answers 403 `mfa_required` — the caller must prompt
/// for a fresh MFA verification and retry (see [withMfa]).
class MfaRequiredException implements Exception {
  const MfaRequiredException([this.accountId]);

  /// The account the step-up is needed for, when the client already knows
  /// it (most callers do — it's the org/emergency owner's own account).
  final String? accountId;

  @override
  String toString() => 'MfaRequiredException(accountId: $accountId)';
}

/// Maps a failed MFA-API (or any MFA-gated) call to one of [MfaErrorCodes],
/// or null when it isn't one of the documented MFA errors.
String? mfaErrorCode(Object error) {
  if (error is! DioException) return null;
  final body = error.response?.data;
  if (body is Map && body['code'] is String) return body['code'] as String;
  return null;
}

/// [_StepUpInterceptor] (api_client.dart) tags a 403 `mfa_required` response
/// with an [MfaRequiredException] as the DioException's `error`, but Dio
/// itself always throws the DioException wrapper, never the inner error
/// directly. This unwraps it so callers can `catch (e) { if (e is
/// MfaRequiredException) ... }` without knowing about Dio at all.
Object unwrapMfaError(Object error) =>
    error is DioException && error.error is MfaRequiredException
    ? error.error!
    : error;

/// Runs [action]; if it fails with [MfaRequiredException] (a 403
/// `mfa_required`, tagged by [_StepUpInterceptor] and unwrapped here), calls
/// [promptAndVerify] ONCE and, if it returns true, retries [action] ONCE.
/// No further retries — a second failure is a real error, not something to
/// loop on.
Future<T> withMfa<T>(
  Future<T> Function() action,
  Future<bool> Function() promptAndVerify,
) async {
  try {
    return await action();
  } catch (error) {
    if (unwrapMfaError(error) is! MfaRequiredException) rethrow;
    if (!await promptAndVerify()) throw unwrapMfaError(error);
    return action();
  }
}
