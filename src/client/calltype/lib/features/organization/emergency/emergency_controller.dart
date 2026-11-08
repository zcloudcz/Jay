import 'package:calltype_core/network/emergency_api.dart';
import 'package:calltype_core/network/emergency_dtos.dart';
import 'package:calltype_core/network/mfa_api.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/storage/database.dart';

/// Drives the Emergency channel screens (E07): admin kit/drill management
/// for org admins, plus the "I have an emergency code" enroll flow any
/// device can use. Thin wrapper over [EmergencyApi], same shape as
/// [OrganizationController].
///
/// Every admin call is gated server-side by N03b on a step-up token — [_run]
/// wraps each one in [withMfa], same as [OrganizationController]. The
/// "I have a code" enroll path below is deliberately NOT gated (a bare
/// device with no account has no MFA to check).
class EmergencyController extends ChangeNotifier {
  EmergencyController({required ApiClient apiClient, required this.organizationId})
    : _api = apiClient;

  final ApiClient _api;
  final String organizationId;
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
  List<EmergencyKitInfo> kits = const [];
  List<EmergencyDrillInfo> drills = const [];
  /// The most recently issued kit's plaintext codes — cleared once the admin
  /// navigates away from the "shown once" dialog so it can never be
  /// re-displayed from app state.
  IssuedEmergencyKit? justIssuedKit;
  /// One of [EmergencyErrorCodes], or null.
  String? errorCode;

  /// Set by the screen after mount, same contract as
  /// `OrganizationController.promptForMfa`.
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
        errorCode = emergencyErrorCode(e) ?? 'unknown';
      }
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> load() => _run(() async {
    kits = await _api.getEmergencyKits(organizationId);
    drills = await _api.getEmergencyDrills(organizationId);
  });

  Future<void> issueKit(String label, int count) => _run(() async {
    justIssuedKit = await _api.issueEmergencyKit(
      organizationId,
      label: label,
      count: count,
    );
    kits = await _api.getEmergencyKits(organizationId);
  });

  /// Called once the admin has copied/shared/dismissed the just-issued kit's
  /// codes — the app never shows them again, matching the server's own
  /// "returned once" guarantee.
  void clearJustIssuedKit() {
    justIssuedKit = null;
    notifyListeners();
  }

  Future<void> revokeKit(String kitId) => _run(() async {
    await _api.revokeEmergencyKit(organizationId, kitId);
    kits = await _api.getEmergencyKits(organizationId);
  });

  Future<void> startDrill() => _run(() async {
    await _api.startEmergencyDrill(organizationId);
    drills = await _api.getEmergencyDrills(organizationId);
  });

  Future<void> completeDrill(int drillId) => _run(() async {
    await _api.completeEmergencyDrill(organizationId, drillId);
    drills = await _api.getEmergencyDrills(organizationId);
  });

  Future<List<int>?> exportProof({String format = 'txt'}) async {
    List<int>? bytes;
    await _run(() async {
      bytes = await _api.exportEmergencyProof(organizationId, format: format);
    });
    return bytes;
  }
}

/// Standalone helper for the "I have an emergency code" flow — deliberately
/// NOT tied to an [organizationId] (the code alone determines it), so it
/// isn't part of [EmergencyController], which always operates on one org.
class EmergencyEnrollController extends ChangeNotifier {
  EmergencyEnrollController({required ApiClient apiClient, required AppDatabase database})
    : _api = apiClient,
      _db = database;

  final ApiClient _api;
  final AppDatabase _db;
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
  String? errorCode;
  String? enrolledOrganizationId;
  /// The emergency group's local conversation id, set once [enroll] has
  /// ensured a local row for it exists — the screen navigates straight here
  /// instead of the chat list once this is non-null.
  String? enrolledConversationId;

  /// [fallbackTitle] is shown in the chat list only if this device has never
  /// seen the conversation before — the caller passes the localized
  /// `emergencyTitle` string since this controller has no `BuildContext` of
  /// its own to read `l10n` from (project convention: code without a
  /// `BuildContext` never hardcodes user-visible text).
  Future<void> enroll(String code, {required String fallbackTitle}) async {
    isLoading = true;
    errorCode = null;
    notifyListeners();
    try {
      final result = await _api.enrollWithEmergencyCode(code);
      enrolledOrganizationId = result.organizationId;
      if (result.groupId != null) {
        await _ensureConversation(result.groupId!, fallbackTitle);
        enrolledConversationId = result.groupId;
      }
    } catch (e) {
      errorCode = emergencyErrorCode(e) ?? 'unknown';
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// Creates the local conversation row for the emergency group if this
  /// device hasn't seen it before — same shape as [GroupController.createGroup],
  /// but here the group already exists server-side (created on kit issue),
  /// so there is nothing to insert except the local row.
  Future<void> _ensureConversation(String groupId, String fallbackTitle) async {
    final exists = await (_db.select(_db.conversations)
          ..where((c) => c.id.equals(groupId)))
        .getSingleOrNull();
    if (exists != null) return;

    await _db.into(_db.conversations).insert(
      ConversationsCompanion.insert(id: groupId, type: 'group', title: Value(fallbackTitle)),
    );
  }
}
