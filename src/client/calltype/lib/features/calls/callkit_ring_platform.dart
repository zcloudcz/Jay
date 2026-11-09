import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart' show RemoteMessage;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show basicLocaleListResolution;
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';

import '../../core/network/push_service.dart';
import '../../l10n/l10n.dart';
import 'call_ring.dart';

/// [CallRingPlatform] on flutter_callkit_incoming (pinned in pubspec.yaml):
/// CallKit on iOS, the plugin's full-screen incoming call on Android.
class CallkitRingPlatform
    implements CallRingPlatform, VoipTokenSource, FullScreenIntentAccess {
  CallkitRingPlatform({AppLocalizations Function()? strings})
    : _strings = strings ?? ringStrings;

  final AppLocalizations Function() _strings;

  /// The plugin's EventChannel builds a new stream per access; one shared
  /// broadcast stream keeps a single native listener.
  late final Stream<CallEvent?> _raw = FlutterCallkitIncoming.onEvent
      .handleError((Object _) {})
      .asBroadcastStream();

  /// System ids of non-UUID call ids (see [ringIdFor]) back to the call id.
  final _callIds = <String, String>{};

  @override
  bool get showsMissedOnTimeout => _isAndroid;

  @override
  Stream<RingEvent> get events =>
      _raw.map(_toRingEvent).where((e) => e != null).cast<RingEvent>();

  @override
  Stream<String> get changes => _raw
      .where((e) => e is CallEventActionDidUpdateDevicePushTokenVoip)
      .asyncMap((_) async => await token() ?? '');

  @override
  Future<String?> token() async {
    if (!_isIos) return null;
    return FlutterCallkitIncoming.getDevicePushTokenVoIP();
  }

  @override
  Future<void> showIncoming(IncomingRing ring) =>
      FlutterCallkitIncoming.showCallkitIncoming(ringParams(ring, _strings()));

  @override
  Future<void> end(String callId) =>
      FlutterCallkitIncoming.endCall(ringIdFor(callId));

  @override
  Future<void> setConnected(String callId) =>
      FlutterCallkitIncoming.setCallConnected(ringIdFor(callId));

  @override
  Future<List<ActiveRing>> activeCalls() async {
    final calls = await FlutterCallkitIncoming.activeCalls();
    return [
      for (final call in calls)
        ActiveRing(
          callId: _remember(call),
          accepted: call.isAccepted,
          ringingSince: _ringingSince(call.extra),
        ),
    ];
  }

  /// Android 14+: may the app show the incoming call full screen on the
  /// lock screen? True elsewhere (no such permission).
  @override
  Future<bool> canUseFullScreenIntent() async {
    if (!_isAndroid) return true;
    try {
      return await FlutterCallkitIncoming.canUseFullScreenIntent();
    } catch (_) {
      return true;
    }
  }

  /// Opens the system setting for the full-screen permission (Android 14+).
  @override
  Future<void> requestFullScreenIntent() async {
    if (!_isAndroid) return;
    try {
      await FlutterCallkitIncoming.requestFullIntentPermission();
    } catch (_) {}
  }

  RingEvent? _toRingEvent(CallEvent? event) => switch (event) {
    CallEventActionCallIncoming(:final callKitParams) => RingIncoming(
      _remember(callKitParams),
    ),
    CallEventActionCallAccept(:final callKitParams) => RingAccepted(
      _remember(callKitParams),
    ),
    CallEventActionCallDecline(:final callKitParams) => RingDeclined(
      _remember(callKitParams),
    ),
    CallEventActionCallEnded(:final callKitParams) => RingEnded(
      _remember(callKitParams),
    ),
    CallEventActionCallTimeout(:final id) => RingTimedOut(_callIdOf(id)),
    CallEventActionCallToggleMute(:final id, :final isMuted) => RingMuted(
      _callIdOf(id),
      isMuted,
    ),
    // Hold has no meaning for a WebRTC call here: mute while on hold.
    CallEventActionCallToggleHold(:final id, :final isOnHold) => RingMuted(
      _callIdOf(id),
      isOnHold,
    ),
    _ => null,
  };

  String _remember(CallKitParams params) {
    final callId = params.extra?['callId'];
    final id = params.id.toLowerCase();
    if (callId is String && callId.isNotEmpty) {
      _callIds[id] = callId;
      return callId;
    }
    return id;
  }

  String _callIdOf(String systemId) =>
      _callIds[systemId.toLowerCase()] ?? systemId.toLowerCase();

  static DateTime? _ringingSince(Map<String, dynamic>? extra) {
    final ts = extra?['ts'];
    final ms = ts is num ? ts.toInt() : int.tryParse('$ts');
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }
}

bool get _isAndroid =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
bool get _isIos => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

/// Whether this platform rings closed-app calls through the system UI.
bool get ringsInSystemUi => _isAndroid || _isIos;

/// The texts of the system call UI, in the OS language. Works without a
/// BuildContext and in the FCM background isolate (the Android embedding
/// sends the locale list to every engine; without one it is English, the
/// app's fallback language).
AppLocalizations ringStrings() => lookupAppLocalizations(
  basicLocaleListResolution(
    PlatformDispatcher.instance.locales,
    AppLocalizations.supportedLocales,
  ),
);

/// The incoming call as the plugin shows it: "Jay" + "Incoming call" and no
/// caller data at all (R4: the push carries none).
CallKitParams ringParams(IncomingRing ring, AppLocalizations l10n) =>
    CallKitParams(
      id: ringIdFor(ring.callId),
      nameCaller: 'Jay',
      appName: 'Jay',
      handle: l10n.notificationIncomingCall,
      type: 0,
      // The caller rings for 45 s (WebRTCManager); so does this side.
      duration: 45000,
      extra: <String, dynamic>{
        'callId': ring.callId,
        'conversationId': ?ring.conversationId,
        'ts': DateTime.now().millisecondsSinceEpoch,
      },
      missedCallNotification: NotificationParams(
        showNotification: true,
        isShowCallback: false,
        subtitle: l10n.notificationMissedCall,
      ),
      callingNotification: NotificationParams(
        showNotification: true,
        isShowCallback: true,
        subtitle: l10n.callTitle,
        callbackText: l10n.callEnd,
      ),
      android: AndroidParams(
        textAccept: l10n.callAccept,
        textDecline: l10n.callDecline,
        isCustomNotification: true,
        isShowLogo: false,
        isShowCallID: false,
        isShowFullLockedScreen: true,
        ringtonePath: 'system_ringtone_default',
        backgroundColor: '#003840',
        actionColor: '#4CAF50',
        textColor: '#ffffff',
        incomingCallNotificationChannelName: l10n.notificationChannelCalls,
        missedCallNotificationChannelName: l10n.notificationChannelMissedCalls,
      ),
      ios: const IOSParams(
        handleType: 'generic',
        supportsVideo: false,
        maximumCallGroups: 1,
        maximumCallsPerCallGroup: 1,
        audioSessionMode: 'voiceChat',
        supportsDTMF: false,
        supportsHolding: false,
        supportsGrouping: false,
        supportsUngrouping: false,
        includesCallsInRecents: false,
      ),
    );

/// FCM data message handler for a closed Android app (spec section 2,
/// Android): `incoming_call` shows the full-screen call, `call_cancelled`
/// ends it and leaves a missed-call notification. Runs in the background
/// isolate firebase_messaging starts, so it only uses the plugin.
Future<void> handleRingPush(Map<String, Object?> data) async {
  final strings = ringStrings();
  final incoming = IncomingRing.fromPush(data);
  if (incoming != null) {
    await FlutterCallkitIncoming.showCallkitIncoming(
      ringParams(incoming, strings),
    );
    return;
  }
  final cancelled = IncomingRing.fromPush(data, type: ringPushCancelled);
  if (cancelled != null) {
    final params = ringParams(cancelled, strings);
    await FlutterCallkitIncoming.endCall(params.id);
    await FlutterCallkitIncoming.showMissCallNotification(params);
  }
}

/// The firebase_messaging background entry point (Android). Top level and
/// kept by the compiler for the background isolate.
@pragma('vm:entry-point')
Future<void> ringPushBackgroundHandler(RemoteMessage message) async {
  try {
    await handleRingPush(message.data);
  } catch (_) {
    // Nothing to report to in a background isolate; the next hub connect
    // still delivers the pending call or its `cancelled` tombstone.
  }
}
