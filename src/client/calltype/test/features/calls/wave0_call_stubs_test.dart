import 'package:calltype/core/network/api_client.dart';
import 'package:calltype/core/network/signalr_client.dart';
import 'package:calltype/core/network/webrtc_manager.dart';
import 'package:calltype/features/calls/call_push_handler.dart';
import 'package:calltype/features/calls/locked_call_view.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/localized_app.dart';

// Wave-0 stubs (contracts K6, K10). Stream C replaces the bodies and brings
// its own tests (call_push_handler_test.dart, locked_call_view_test.dart);
// these only pin that the seams exist and are harmless until then.
void main() {
  test('handleCallPush ignores call and call_cancel pushes for now', () async {
    await handleCallPush({'type': 'call', 'callId': 'c1', 'video': '1'});
    await handleCallPush({'type': 'call_cancel', 'callId': 'c1'});
  });

  testWidgets('LockedCallView builds without a router or overlay', (
    tester,
  ) async {
    final manager = WebRTCManager(
      signalRClient: SignalRClient(baseUrl: 'http://unused', deviceId: 'me'),
      apiClient: ApiClient(baseUrl: 'http://unused'),
      myDeviceId: 'me',
    );
    await tester.pumpWidget(
      localizedApp(home: LockedCallView(webrtcManager: manager)),
    );
    expect(find.byType(LockedCallView), findsOneWidget);
    expect(tester.takeException(), isNull);
    manager.dispose();
  });

  testWidgets('LockedCallView renders alone, as SessionOverlay will', (
    tester,
  ) async {
    final manager = WebRTCManager(
      signalRClient: SignalRClient(baseUrl: 'http://unused', deviceId: 'me'),
      apiClient: ApiClient(baseUrl: 'http://unused'),
      myDeviceId: 'me',
    );
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: LockedCallView(webrtcManager: manager, onClosed: () {}),
      ),
    );
    expect(tester.takeException(), isNull);
    manager.dispose();
  });
}
