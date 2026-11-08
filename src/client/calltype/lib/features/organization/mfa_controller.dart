import 'dart:convert';

import 'package:calltype_core/network/mfa_api.dart';
import 'package:calltype_core/network/mfa_dtos.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'package:calltype_core/network/api_client.dart';

/// Drives TOTP MFA (N03d) for the calling account: status, enrolment,
/// verification, disable and backup-code regeneration. See
/// `docs/security/mfa.md` for the server-side contract this wraps.
///
/// Deliberately holds no secret state itself — the enrolment secret,
/// otpauth URI and backup codes all pass straight through from the server
/// response to the screen and are never logged or persisted here.
class MfaController extends ChangeNotifier {
  MfaController({required ApiClient apiClient, required this.accountId})
    : _api = apiClient;

  final ApiClient _api;
  final String accountId;
  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  bool isLoading = false;
  MfaStatus? status;
  /// One of [MfaErrorCodes], or 'unknown'.
  String? errorCode;

  Future<void> _run(Future<void> Function() action) async {
    isLoading = true;
    errorCode = null;
    notifyListeners();
    try {
      await action();
    } catch (e) {
      errorCode = mfaErrorCode(e) ?? 'unknown';
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadStatus() => _run(() async {
    status = await _api.getMfaStatus(accountId);
  });

  /// Same derivation `AccountScreen` uses to log in/link a device — the
  /// server never sees the raw passphrase, only this hash.
  static String authKeyFor(String passphrase) =>
      sha256.convert(utf8.encode(passphrase)).toString();

  Future<MfaEnrollment?> startEnrollment(String passphrase) async {
    MfaEnrollment? enrollment;
    await _run(() async {
      enrollment = await _api.startMfaEnrollment(
        accountId,
        authKeyFor(passphrase),
      );
    });
    return enrollment;
  }

  /// Returns the 10 one-time backup codes on success — the screen must show
  /// them exactly once and never re-request them.
  Future<List<String>?> confirmEnrollment(String code) async {
    List<String>? codes;
    await _run(() async {
      codes = await _api.confirmMfaEnrollment(accountId, code);
      status = await _api.getMfaStatus(accountId);
    });
    return codes;
  }

  /// On success this also stashes a step-up token on the shared [ApiClient]
  /// (see `verifyMfa`), so the caller's next admin request succeeds.
  Future<bool> verify({String? code, String? backupCode}) async {
    var ok = false;
    await _run(() async {
      await _api.verifyMfa(accountId, code: code, backupCode: backupCode);
      ok = true;
    });
    return ok;
  }

  Future<void> disable(String code) => _run(() async {
    await _api.disableMfa(accountId, code);
    status = await _api.getMfaStatus(accountId);
  });

  Future<List<String>?> regenerateBackupCodes() async {
    List<String>? codes;
    await _run(() async {
      codes = await _api.regenerateMfaBackupCodes(accountId);
      status = await _api.getMfaStatus(accountId);
    });
    return codes;
  }
}
