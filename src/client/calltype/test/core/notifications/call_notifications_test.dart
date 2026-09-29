import 'package:calltype/core/notifications/call_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('NoopCallNotifications accepts every call and never taps', () async {
    const CallNotifications n = NoopCallNotifications();
    await n.showIncomingCall(
      callId: 'c1',
      title: 'Incoming call',
      body: 'Alice',
      video: true,
    );
    await n.cancelIncomingCall('c1');
    await n.showMissedCall(
      callId: 'c1',
      title: 'Missed call',
      body: 'Alice',
      conversationId: 'conv-1',
    );
    await n.cancelMissedCalls();
    expect(await n.tapped.isEmpty, isTrue);
  });
}
