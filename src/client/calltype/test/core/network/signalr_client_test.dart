import 'package:calltype/core/network/signalr_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('offline send fails instead of claiming successful delivery', () async {
    final client = SignalRClient(
      baseUrl: 'http://localhost',
      deviceId: 'device',
    );
    addTearDown(client.dispose);
    await expectLater(
      client.sendMessage('recipient', 'ciphertext'),
      throwsStateError,
    );
    await expectLater(
      client.sendGroupMessage('group', {'recipient': 'ciphertext'}),
      throwsStateError,
    );
    await expectLater(
      client.sendCallSignal('recipient', 'offer', 'sdp'),
      throwsStateError,
    );
  });
}
