import 'package:calltype_core/crypto/signal_protocol.dart';
import 'package:test/test.dart';

import 'drift_vector_device.dart';
import 'vector_scenario.dart';

void main() {
  tearDown(() => SignalProtocol.testRandomBytes = null);

  test('session v2 vectors replay byte for byte (drift store)', () async {
    final expected = loadVectors();
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
