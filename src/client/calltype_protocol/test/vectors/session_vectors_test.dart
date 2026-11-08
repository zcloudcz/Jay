import 'package:calltype_protocol/crypto/signal_protocol.dart';
import 'package:calltype_protocol/testing/memory_vector_device.dart';
import 'package:calltype_protocol/testing/session_vector_scenario.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() => SignalProtocol.testRandomBytes = null);

  test('session v2 vectors replay byte for byte (memory store)', () async {
    final expected = loadVectors();
    final actual = await runSessionScenario(
      factory: memoryVectorDevice,
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

  test('regenerating from the code gives the committed file exactly', () async {
    final vectors = await runSessionScenario(
      factory: memoryVectorDevice,
      draws: GeneratingDraws(),
    );
    expect(encodeVectors(vectors), encodeVectors(loadVectors()));
  });
}
