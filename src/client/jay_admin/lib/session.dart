import 'package:flutter/foundation.dart';

import 'api/admin_api.dart';
import 'api/models.dart';

/// Why the operator is (back) on the login screen.
enum LogoutReason { none, manual, expired, unauthorized }

/// In-memory operator session (contract 4.1: no refresh, 30 min lifetime).
///
/// WHY in memory only: the token is a moderation credential. Keeping it out of
/// localStorage/sessionStorage means closing or reloading the tab ends the
/// session; the cost is a TOTP prompt after a reload, which is acceptable for
/// a single operator.
///
/// The countdown timer lives in the shell widget (SessionCountdown), not here:
/// a timer owned by the widget tree dies with it, so no background timer keeps
/// running once nobody looks at the page.
class SessionController extends ChangeNotifier {
  SessionController(this.api, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now {
    api.onUnauthorized = () => end(LogoutReason.unauthorized);
  }

  final AdminApi api;
  final DateTime Function() _clock;
  AdminSession? _session;
  LogoutReason _reason = LogoutReason.none;

  AdminSession? get session => _session;
  bool get isLoggedIn => _session != null;
  LogoutReason get lastReason => _reason;

  Duration get remaining {
    final s = _session;
    if (s == null) return Duration.zero;
    final left = s.expiresAt.difference(_clock().toUtc());
    return left.isNegative ? Duration.zero : left;
  }

  Future<void> login({
    required String email,
    required String passphrase,
    String? code,
    String? backupCode,
  }) async {
    final s = await api.createSession(
      email: email,
      passphrase: passphrase,
      code: code,
      backupCode: backupCode,
    );
    api.setToken(s.token);
    _session = s;
    _reason = LogoutReason.none;
    notifyListeners();
  }

  /// Ends the session locally. Called on logout, on local expiry and on any
  /// 401 from the API (token expired or revoked server-side).
  void end(LogoutReason reason) {
    final wasLoggedIn = _session != null;
    _session = null;
    api.setToken(null);
    _reason = reason;
    if (wasLoggedIn || reason != LogoutReason.none) notifyListeners();
  }

  /// Ends the session if its time is up; returns true when it did.
  bool expireIfDue() {
    if (_session != null && remaining == Duration.zero) {
      end(LogoutReason.expired);
      return true;
    }
    return false;
  }
}
