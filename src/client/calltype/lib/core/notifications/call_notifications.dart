/// Visible notifications about calls (contracts K7, calls plan KC7).
///
/// Stream N implements it (web, desktop, missed calls on every platform);
/// stream C calls it. On mobile the incoming call itself is shown by
/// CallKit / Telecom (`flutter_callkit_incoming`), never through this
/// interface — one visible path per platform, so a call never rings twice.
///
/// The texts arrive already localized: C has a BuildContext (or
/// `lookupAppLocalizations`), N translates nothing.
abstract class CallNotifications {
  /// Web/desktop only: a visible "incoming call" notification.
  Future<void> showIncomingCall({
    required String callId,
    required String title,
    required String body,
    required bool video,
  });

  Future<void> cancelIncomingCall(String callId);

  /// All platforms: one notification per missed incoming call.
  Future<void> showMissedCall({
    required String callId,
    required String title,
    required String body,
    String? conversationId,
  });

  Future<void> cancelMissedCalls();

  /// callId of a tapped incoming/missed-call notification.
  Stream<String> get tapped;
}

/// Wave-0 default until stream N provides the real implementation: shows
/// nothing, so C can already call it unconditionally. Also the fake base for
/// client tests.
class NoopCallNotifications implements CallNotifications {
  const NoopCallNotifications();

  @override
  Future<void> showIncomingCall({
    required String callId,
    required String title,
    required String body,
    required bool video,
  }) async {}

  @override
  Future<void> cancelIncomingCall(String callId) async {}

  @override
  Future<void> showMissedCall({
    required String callId,
    required String title,
    required String body,
    String? conversationId,
  }) async {}

  @override
  Future<void> cancelMissedCalls() async {}

  @override
  Stream<String> get tapped => const Stream<String>.empty();
}
