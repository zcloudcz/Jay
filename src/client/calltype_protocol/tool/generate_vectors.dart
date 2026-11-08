// Regenerates test/vectors/session_v2.json from the current implementation.
//
//   dart run tool/generate_vectors.dart [output path]
//
// Only do this on purpose: the committed file is the golden reference that
// test/vectors/session_vectors_test.dart (and calltype_core over its drift
// store) replays. A diff in it means the wire format or the key schedule
// changed. With an output path it writes elsewhere, so a run can be diffed
// against the committed file.
import 'dart:io';

import 'package:calltype_protocol/testing/memory_vector_device.dart';
import 'package:calltype_protocol/testing/session_vector_scenario.dart';

Future<void> main(List<String> args) async {
  final out = args.isEmpty ? vectorFile : args.first;
  final vectors = await runSessionScenario(
    factory: memoryVectorDevice,
    draws: GeneratingDraws(),
  );
  File(out).writeAsStringSync(encodeVectors(vectors));
  stdout.writeln('wrote $out (${(vectors['steps'] as List).length} steps)');
}
