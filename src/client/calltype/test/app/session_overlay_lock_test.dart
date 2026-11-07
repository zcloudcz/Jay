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

class _Lock extends AppLock {
  _Lock() : super(secureStorage: SecureStorage());
  bool enabled = false;
  @override
  Future<bool> isEnabled() async => enabled;
  @override
  Future<bool> verifyPin(String pin) async => pin == '1234';
}

/// iOS beta finding: text typed in a chat was gone after switching apps with
/// the app lock on. The overlay used to REPLACE the app with the lock
/// screen, which disposed the open chat and its composer.
void main() {
  testWidgets('the app stays mounted under the lock: typed text survives, '
      'nothing behind the lock is visible, focusable or tappable', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final lock = _Lock();
    final calls = WebRTCManager(
      signalRClient: SignalRClient(baseUrl: 'http://unused', deviceId: 'me'),
      apiClient: ApiClient(baseUrl: 'http://unused'),
      myDeviceId: 'me',
    );
    addTearDown(calls.dispose);
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final focus = FocusNode();
    addTearDown(focus.dispose);
    var taps = 0;

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<AppLock>.value(value: lock),
          ChangeNotifierProvider.value(value: calls),
        ],
        child: localizedApp(
          home: SessionOverlay(
            openCall: (_) {},
            child: Scaffold(
              body: Column(
                children: [
                  // A State of its own, like the composer: lost if the
                  // subtree is disposed.
                  const _Counter(),
                  TextField(controller: controller, focusNode: focus),
                  TextButton(
                    onPressed: () => taps++,
                    child: const Text('behind'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('count 0'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'half a sentence');
    expect(focus.hasFocus, isTrue);

    // Going to the background with the lock on.
    lock.enabled = true;
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    expect(find.text(l10nEn.lockUnlockTitle), findsOneWidget);
    expect(find.text('behind'), findsNothing, reason: 'offstage, not shown');
    expect(find.text('count 1'), findsNothing);
    expect(
      focus.hasFocus,
      isFalse,
      reason: 'a focused composer would raise the keyboard over the lock',
    );
    final behind = find.text('behind', skipOffstage: false);
    expect(behind, findsOneWidget, reason: 'still mounted');
    await tester.tap(behind, warnIfMissed: false);
    expect(taps, 0);
    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel('behind'), findsNothing);
    semantics.dispose();

    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.enterText(
      find.widgetWithText(TextField, l10nEn.lockPinLabel),
      '1234',
    );
    await tester.tap(find.text(l10nEn.lockUnlockButton));
    await tester.pumpAndSettle();

    expect(find.text(l10nEn.lockUnlockTitle), findsNothing);
    expect(controller.text, 'half a sentence');
    expect(find.text('half a sentence'), findsOneWidget);
    expect(find.text('count 1'), findsOneWidget, reason: 'state kept');
    await tester.tap(find.text('behind'));
    expect(taps, 1);
  });

  testWidgets('a cold start with the lock on builds nothing of the app', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final lock = _Lock()..enabled = true;
    final calls = WebRTCManager(
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
    expect(find.text(l10nEn.lockUnlockTitle), findsOneWidget);
    expect(find.text('app', skipOffstage: false), findsNothing);
  });
}

class _Counter extends StatefulWidget {
  const _Counter();
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int _count = 0;
  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => setState(() => _count++),
    child: Text('count $_count'),
  );
}
