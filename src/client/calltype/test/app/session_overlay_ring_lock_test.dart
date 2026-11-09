import 'dart:async';
import 'dart:convert';

import 'package:calltype/app/session_overlay.dart';
import 'package:calltype/core/auth/app_lock.dart';
import 'package:calltype/core/network/signalr_client.dart';
import 'package:calltype/core/network/webrtc_manager.dart';
import 'package:calltype/core/storage/secure_storage.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../helpers/localized_app.dart';

class _BioLock extends AppLock {
  _BioLock() : super(secureStorage: SecureStorage());
  final answers = <bool>[];
  int prompts = 0;

  @override
  Future<bool> isEnabled() async => true;
  @override
  Future<bool> verifyPin(String pin) async => pin == '1234';
  @override
  Future<bool> isBiometricEnabled() async => true;
  @override
  Future<bool> isBiometricAvailable() async => true;
  @override
  Future<bool> authenticateWithBiometrics({required String reason}) {
    prompts++;
    return Future.value(answers.isEmpty ? false : answers.removeAt(0));
  }
}

class _Signal extends SignalRClient {
  _Signal() : super(baseUrl: 'http://unused', deviceId: 'me');
  final signals = StreamController<Map<String, dynamic>>.broadcast();
  @override
  Stream<Map<String, dynamic>> get onCallSignal => signals.stream;
  @override
  Future<void> sendCallSignal(
    String peer,
    String type,
    String payload, {
    String? businessGroupId,
  }) async {}

  void send(String type, String callId, String payload) => signals.add({
    'senderId': 'caller',
    'signalType': type,
    'payload': jsonEncode({'v': 1, 'callId': callId, 'payload': payload}),
  });
}

/// Call ringing merged with the biometric auto-prompt (ffbb039): a call that
/// rings in CallKit / the Android full-screen UI must neither trigger extra
/// lock prompts nor open the in-app call screen behind the system UI.
void main() {
  const callId = '11223344-5566-4788-9900-aabbccddeeff';

  testWidgets('a call ringing in the system UI over a locked app does not '
      'add lock prompts or open the call screen', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final signal = _Signal();
    final calls = WebRTCManager(
      signalRClient: signal,
      apiClient: ApiClient(baseUrl: 'http://unused'),
      myDeviceId: 'me',
    );
    addTearDown(calls.dispose);
    final lock = _BioLock()..answers.add(false);
    final opened = <String>[];

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<AppLock>.value(value: lock),
          ChangeNotifierProvider.value(value: calls),
        ],
        child: localizedApp(
          home: SessionOverlay(openCall: opened.add, child: const Text('app')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(lock.prompts, 1, reason: 'cold start asks once');

    calls.markSystemCall(callId);
    signal.send('offer', callId, 'v=0\r\nm=audio');
    await tester.pumpAndSettle();
    expect(calls.isIncoming, isTrue);
    expect(calls.ringsInSystemUi, isTrue);
    expect(lock.prompts, 1, reason: 'a ringing call does not re-prompt');
    expect(opened, isEmpty);

    // Coming back to the app (e.g. from the CallKit screen) asks once more.
    lock.answers.add(true);
    for (final s in const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    await tester.pumpAndSettle();
    expect(lock.prompts, 2);
    expect(find.text('app'), findsOneWidget);
    expect(
      opened,
      isEmpty,
      reason: 'the system UI rings, the in-app screen opens on accept',
    );

    signal.send('hangup', callId, '');
    await tester.pumpAndSettle();
    expect(lock.prompts, 2, reason: 'no prompt loop');
    expect(opened, isEmpty);
  });
}
