import 'package:calltype_protocol/crypto/signal_protocol.dart';
import 'package:calltype_protocol/testing/session_vector_scenario.dart';
import 'package:test/test.dart';

import 'drift_vector_device.dart';

/// The protocol's golden vectors (calltype_protocol/test/vectors) replayed
/// over the client's drift store: proves DriftProtocolStore persists and
/// restores sessions without changing a single byte on the wire.
void main() {
  tearDown(() => SignalProtocol.testRandomBytes = null);

  test('session v2 vectors replay byte for byte (drift store)', () async {
    final expected = loadVectors('../calltype_protocol/$vectorFile');
    final actual = await runSessionScenario(
      factory: driftVectorDevice,
      draws: ReplayDraws(expected['steps'] as List),
      expected: expected,
    );
    expect(actual['devices'], equals(expected['devices']));
    expect(actual['bobBundle'], equals(expected['bobBundle']));
    expect(actual['x3dh'], equals(expected['x3dh']));
    final steps = expected['steps'] as List;
    expect((actual['steps'] as List).length, steps.length);
    for (var i = 0; i < steps.length; i++) {
      expect(actual['steps'][i], equals(steps[i]), reason: 'step $i');
    }
  });
}
