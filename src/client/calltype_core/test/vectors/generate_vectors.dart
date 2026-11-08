// Regenerates test/vectors/session_v2.json from the current implementation.
//
//   dart run test/vectors/generate_vectors.dart
//
// Only do this on purpose: the committed file is the golden reference that
// session_vectors_test.dart replays. A diff in it means the wire format or
// the key schedule changed.
import 'dart:io';

import 'drift_vector_device.dart';
import 'vector_scenario.dart';

Future<void> main() async {
  final vectors = await runSessionScenario(
    factory: driftVectorDevice,
    draws: GeneratingDraws(),
  );
  File(vectorFile).writeAsStringSync(encodeVectors(vectors));
  stdout.writeln(
    'wrote $vectorFile (${(vectors['steps'] as List).length} steps)',
  );
}
