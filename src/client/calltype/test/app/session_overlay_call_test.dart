import 'dart:async';
import 'dart:convert';

import 'package:calltype/app/session_overlay.dart';
import 'package:calltype/core/auth/app_lock.dart';
import 'package:calltype/core/network/api_client.dart';
import 'package:calltype/core/network/signalr_client.dart';
import 'package:calltype/core/network/webrtc_manager.dart';
import 'package:calltype/core/storage/secure_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../helpers/localized_app.dart';

class _Signal extends SignalRClient {
  _Signal() : super(baseUrl: 'http://unused', deviceId: 'me');
  final signals = StreamController<Map<String, dynamic>>.broadcast();
  @override
  Stream<Map<String, dynamic>> get onCallSignal => signals.stream;
  @override
  Future<void> sendCallSignal(String peer, String type, String payload, {String? businessGroupId}) async {}

  void offer(String callId) => signals.add({
    'senderId': 'caller',
    'signalType': 'offer',
    'payload': jsonEncode({'v': 1, 'callId': callId, 'payload': 'v=0\r\nm=audio'}),
  });

  void hangup(String callId) => signals.add({
    'senderId': 'caller',
    'signalType': 'hangup',
    'payload': jsonEncode({'v': 1, 'callId': callId, 'payload': ''}),
  });
}

/// Beta finding 2026-09-18: "the first call connects, the second one usually
/// cannot be established". The overlay cleared its "call screen is open" flag
/// only when the pushed route's future completed — but the call screen closes
/// with `context.go('/chats')`, and go_router never completes a push() future
/// whose page was removed by go(). After the first call the flag stayed set, so
/// the next call never opened the call screen and the callee could not accept.
void main() {
  testWidgets('every new call opens the call screen, not only the first one', (tester) async {
    FlutterSecureStorage.setMockInitialValues({}); // no PIN -> overlay is unlocked
    final signal = _Signal();
    final calls = WebRTCManager(
      signalRClient: signal,
      apiClient: ApiClient(baseUrl: 'http://unused'),
      myDeviceId: 'me',
    );
    addTearDown(calls.dispose);
    final opened = <String>[];

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider.value(value: AppLock(secureStorage: SecureStorage())),
          ChangeNotifierProvider.value(value: calls),
        ],
        // openCall stands in for router.push: like the real one after go(), it
        // never reports back that the screen was closed.
        child: localizedApp(home: SessionOverlay(openCall: opened.add, child: const SizedBox())),
      ),
    );
    await tester.pumpAndSettle();

    signal.offer('00000000-0000-4000-8000-000000000001');
    await tester.pumpAndSettle();
    expect(opened, ['caller']);

    signal.hangup('00000000-0000-4000-8000-000000000001');
    await tester.pumpAndSettle();
    expect(calls.state, CallState.ended);

    signal.offer('00000000-0000-4000-8000-000000000002');
    await tester.pumpAndSettle();
    expect(opened, ['caller', 'caller'], reason: 'the second incoming call must open the call screen too');

    // Decline, so the 45 s ring timeout is not left pending when the test ends.
    await calls.endCall();
    await tester.pumpAndSettle();
  });
}
