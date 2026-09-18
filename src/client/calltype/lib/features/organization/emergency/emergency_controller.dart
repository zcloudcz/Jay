import 'package:calltype_core/network/emergency_api.dart';
import 'package:calltype_core/network/emergency_dtos.dart';
import 'package:flutter/foundation.dart';

import '../../../core/network/api_client.dart';

/// Drives the Emergency channel screens (E07): admin kit/drill management
/// for org admins, plus the "I have an emergency code" enroll flow any
/// device can use. Thin wrapper over [EmergencyApi], same shape as
/// [OrganizationController].
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

  Future<void> _run(Future<void> Function() action) async {
    isLoading = true;
    errorCode = null;
    notifyListeners();
    try {
      await action();
    } catch (e) {
      errorCode = emergencyErrorCode(e) ?? 'unknown';
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
  EmergencyEnrollController({required ApiClient apiClient}) : _api = apiClient;

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
  String? errorCode;
  String? enrolledOrganizationId;

  Future<void> enroll(String code) async {
    isLoading = true;
    errorCode = null;
    notifyListeners();
    try {
      enrolledOrganizationId = await _api.enrollWithEmergencyCode(code);
    } catch (e) {
      errorCode = emergencyErrorCode(e) ?? 'unknown';
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }
}
