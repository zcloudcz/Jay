import 'dart:async';

import 'package:calltype/app/session_overlay.dart';
import 'package:calltype/core/auth/app_lock.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype/core/network/signalr_client.dart';
import 'package:calltype/core/network/webrtc_manager.dart';
import 'package:calltype/core/storage/secure_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../helpers/localized_app.dart';

/// Lock with biometrics turned on; each prompt is answered from [answers]
/// (true = recognized, false = cancelled), or held open by [pending].
class _BioLock extends AppLock {
  _BioLock() : super(secureStorage: SecureStorage());
  bool enabled = true;
  bool biometricEnabled = true;
  bool available = true;
  final answers = <bool>[];
  Completer<bool>? pending;
  int prompts = 0;

  @override
  Future<bool> isEnabled() async => enabled;
  @override
  Future<bool> verifyPin(String pin) async => pin == '1234';
  @override
  Future<bool> isBiometricEnabled() async => biometricEnabled;
  @override
  Future<bool> isBiometricAvailable() async => available;
  @override
  Future<bool> authenticateWithBiometrics({required String reason}) {
    prompts++;
    if (pending != null) return pending!.future;
    return Future.value(answers.isEmpty ? false : answers.removeAt(0));
  }
}

/// Owner feedback (2026-11-09): with biometrics on, the lock screen should
/// ask for the fingerprint / face by itself instead of waiting for a tap on
/// "Use biometrics", like other apps.
void main() {
  late WebRTCManager calls;

  Future<void> pump(WidgetTester tester, _BioLock lock) async {
    FlutterSecureStorage.setMockInitialValues({});
    calls = WebRTCManager(
      signalRClient: SignalRClient(baseUrl: 'http://unused', deviceId: 'me'),
      apiClient: ApiClient(baseUrl: 'http://unused'),
      myDeviceId: 'me',
    );
    addTearDown(calls.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<AppLock>.value(value: lock),
          ChangeNotifierProvider.value(value: calls),
        ],
        child: localizedApp(
          home: SessionOverlay(openCall: (_) {}, child: const Text('app')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void lifecycle(WidgetTester tester, List<AppLifecycleState> states) {
    for (final state in states) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
  }

  const toBackground = [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ];
  const toForeground = [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ];

  testWidgets('a cold start asks for biometrics by itself and unlocks', (
    tester,
  ) async {
    final lock = _BioLock()..answers.add(true);
    await pump(tester, lock);
    expect(lock.prompts, 1);
    expect(find.text(l10nEn.lockUnlockTitle), findsNothing);
    expect(find.text('app'), findsOneWidget);
  });

  testWidgets('a cancelled automatic prompt shows no error and does not '
      'come back by itself; the button still works', (tester) async {
    final lock = _BioLock()..answers.addAll([false, true]);
    await pump(tester, lock);
    expect(lock.prompts, 1);
    expect(find.text(l10nEn.lockUnlockTitle), findsOneWidget);
    expect(find.text(l10nEn.lockErrorRejected), findsNothing);

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(lock.prompts, 1, reason: 'no prompt loop after a cancel');

    await tester.tap(find.text(l10nEn.lockUseBiometrics));
    await tester.pumpAndSettle();
    expect(lock.prompts, 2);
    expect(find.text('app'), findsOneWidget);
  });

  testWidgets('returning to the locked app asks again, once', (tester) async {
    // Recognized at the cold start, cancelled after coming back.
    final lock = _BioLock()..answers.addAll([true, false]);
    await pump(tester, lock);
    expect(lock.prompts, 1);
    expect(find.text('app'), findsOneWidget);

    lifecycle(tester, toBackground);
    await tester.pumpAndSettle();
    expect(lock.prompts, 1, reason: 'no prompt while in the background');

    lifecycle(tester, toForeground);
    await tester.pumpAndSettle();
    expect(lock.prompts, 2);
    expect(find.text(l10nEn.lockUnlockTitle), findsOneWidget);
    expect(find.text(l10nEn.lockErrorRejected), findsNothing);
  });

  testWidgets('the system dialog pausing the app (Android device credential) '
      'neither re-locks nor re-prompts', (tester) async {
    final lock = _BioLock()..pending = Completer<bool>();
    await pump(tester, lock);
    expect(lock.prompts, 1);

    // The OS dialog covers the app while it is open.
    lifecycle(tester, toBackground);
    lifecycle(tester, toForeground);
    await tester.pump();
    expect(lock.prompts, 1, reason: 'one dialog at a time');

    lock.pending!.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('app'), findsOneWidget);
  });

  testWidgets('biometrics off or unavailable: no automatic prompt', (
    tester,
  ) async {
    final off = _BioLock()..biometricEnabled = false;
    await pump(tester, off);
    expect(off.prompts, 0);
    expect(find.text(l10nEn.lockUnlockTitle), findsOneWidget);
  });

  testWidgets('no biometric hardware: no automatic prompt', (tester) async {
    final none = _BioLock()..available = false;
    await pump(tester, none);
    expect(none.prompts, 0);
    expect(find.text(l10nEn.lockUnlockTitle), findsOneWidget);
  });
}
