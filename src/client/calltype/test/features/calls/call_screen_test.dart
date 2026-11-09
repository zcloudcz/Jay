import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:calltype/core/network/signalr_client.dart';
import 'package:calltype/core/network/webrtc_manager.dart';
import 'package:calltype/features/calls/call_screen.dart';
import '../../helpers/fake_calls.dart';
import '../../helpers/localized_app.dart';

class ScreenTestApi extends ApiClient {
  ScreenTestApi() : super(baseUrl: 'http://unused');
  @override
  Future<Map<String, dynamic>> getTurnCredentials(String deviceId) async => {};
}

class ScreenTestSignal extends SignalRClient {
  ScreenTestSignal() : super(baseUrl: 'http://unused', deviceId: 'me');
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
}

void main() {
  testWidgets('caller shows Ringing… once the callee is rung, then '
      'Call declined.', (tester) async {
    final signal = CallTestSignal(online: true);
    final manager = testCallManager(signal);
    await tester.pumpWidget(
      localizedApp(home: CallScreen(webrtcManager: manager)),
    );
    await manager.startCall('callee');
    await tester.pump();
    expect(find.text(l10nEn.callStateCalling), findsOneWidget);

    signal.deliver('callee', 'ringing', manager.callId!);
    await tester.pump();
    await tester.pump();
    expect(find.text(l10nEn.callStateRinging), findsOneWidget);

    signal.deliver('callee', 'hangup', manager.callId!, 'declined');
    await tester.pump();
    await tester.pump();
    expect(find.text(l10nEn.callErrorDeclined), findsOneWidget);

    manager.dispose();
    await signal.signals.close();
  });

  testWidgets(
    'business notice is shown before the callee even accepts',
    (tester) async {
      final signal = ScreenTestSignal();
      final manager = WebRTCManager(
        signalRClient: signal,
        apiClient: ScreenTestApi(),
        myDeviceId: 'me',
      );
      signal.signals.add({
        'senderId': 'caller',
        'signalType': 'offer',
        'payload': jsonEncode({
          'v': 1,
          'callId': '11223344-5566-4788-9900-aabbccddeeff',
          'payload': 'v=0',
        }),
        'businessGroupId': 'group-1',
      });
      await tester.pumpAndSettle();

      await tester.pumpWidget(
        localizedApp(home: CallScreen(webrtcManager: manager)),
      );
      await tester.pumpAndSettle();

      expect(find.text(l10nEn.callBusinessNotice), findsOneWidget);

      manager.dispose();
      await signal.signals.close();
    },
  );

  testWidgets('no notice for an anonymous call', (tester) async {
    final signal = ScreenTestSignal();
    final manager = WebRTCManager(
      signalRClient: signal,
      apiClient: ScreenTestApi(),
      myDeviceId: 'me',
      peerFactory: (_) async => _NoopPeer(),
      rendererFactory: RTCVideoRenderer.new,
      mediaFactory: (_) async => Completer<MediaStream>().future,
    );
    unawaited(manager.startCall('other'));
    await tester.pump();

    await tester.pumpWidget(
      localizedApp(home: CallScreen(webrtcManager: manager)),
    );
    await tester.pumpAndSettle();

    expect(find.text(l10nEn.callBusinessNotice), findsNothing);

    manager.dispose();
    await signal.signals.close();
  });
}

class _NoopPeer implements RTCPeerConnection {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
