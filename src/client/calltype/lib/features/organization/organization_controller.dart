import 'package:calltype_core/network/mfa_api.dart';
import 'package:calltype_core/network/organization_api.dart';
import 'package:calltype_core/network/organization_dtos.dart';
import 'package:flutter/foundation.dart';

import '../../core/network/api_client.dart';

/// Drives the Organization settings screen: join/create/manage a business
/// organization. See `docs/superpowers/plans/2026-09-18-business-mode.md`
/// (E05) for what each action means; this controller is a thin wrapper over
/// [OrganizationApi] plus the loading/error state the screen needs.
///
/// Every admin call (anything past "am I a member") is gated server-side by
/// N03b on a step-up token — [_run] wraps each one in [withMfa] so a 403
/// `mfa_required` shows the screen's MFA prompt instead of a raw error.
class OrganizationController extends ChangeNotifier {
  OrganizationController({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;
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
  OrganizationInfo? organization;
  List<OrgMemberInfo> members = const [];
  int? auditRecordCount;
  /// One of [OrgErrorCodes], or null. The screen maps this to localized text
  /// via `l10n.orgErrorGeneric(code)` rather than needing one ARB key per
  /// server error code.
  String? errorCode;

  /// True once an admin call answered `mfa_required` and the user cancelled
  /// the step-up prompt — the screen shows a calm locked state instead of
  /// retrying itself. Set by the screen; null (e.g. in a widget test with no
  /// dialog wired) means every prompt is treated as cancelled.
  Future<bool> Function()? promptForMfa;
  bool locked = false;

  Future<void> _run(Future<void> Function() action) async {
    isLoading = true;
    errorCode = null;
    notifyListeners();
    try {
      await withMfa(action, () => promptForMfa?.call() ?? Future.value(false));
      locked = false;
    } catch (e) {
      if (unwrapMfaError(e) is MfaRequiredException) {
        locked = true;
      } else {
        errorCode = organizationErrorCode(e) ?? 'unknown';
      }
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// GET /orgs/mine — loads the first organization the account belongs to.
  /// (The plan assumes one active organization per device for the MVP UI;
  /// multi-org membership, if it exists server-side, is out of scope here.)
  Future<void> load() => _run(() async {
    final mine = await _api.getMyOrganizations();
    organization = mine.isEmpty ? null : mine.first;
    if (organization != null) {
      members = await _api.getOrganizationMembers(organization!.organizationId);
      if (organization!.isAdmin) {
        auditRecordCount = await _api.getAuditRecordCount(
          organization!.organizationId,
        );
      }
    }
  });

  Future<void> createOrganization(String name) => _run(() async {
    organization = await _api.createOrganization(name);
    members = await _api.getOrganizationMembers(organization!.organizationId);
  });

  Future<void> enroll(String code) => _run(() async {
    final organizationId = await _api.enrollWithInvite(code);
    organization = await _api.getOrganization(organizationId);
  });

  Future<OrgInviteInfo?> createInvite() async {
    if (organization == null) return null;
    OrgInviteInfo? invite;
    await _run(() async {
      invite = await _api.createInvite(organization!.organizationId);
    });
    return invite;
  }

  Future<void> revokeEnrollment(String deviceId) => _run(() async {
    await _api.revokeEnrollment(organization!.organizationId, deviceId);
  });

  Future<void> setAuditorDevice(String deviceId) => _run(() async {
    await _api.setAuditorDevice(organization!.organizationId, deviceId);
    organization = await _api.getOrganization(organization!.organizationId);
  });

  Future<void> setMemberRole(String accountId, String role) => _run(() async {
    await _api.setOrganizationMemberRole(
      organization!.organizationId,
      accountId,
      role,
    );
    members = await _api.getOrganizationMembers(organization!.organizationId);
  });

  Future<List<int>?> exportAdminAudit({String format = 'csv'}) async {
    if (organization == null) return null;
    List<int>? bytes;
    await _run(() async {
      bytes = await _api.exportAdminAudit(
        organization!.organizationId,
        format: format,
      );
    });
    return bytes;
  }
}
