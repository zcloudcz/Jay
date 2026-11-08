// Regenerates the committed test vectors from the current implementation:
// test/vectors/session_v2.json and test/vectors/device_list_v1.json.
//
//   dart run tool/generate_vectors.dart [output dir]
//
// Only do this on purpose: the committed files are the golden reference that
// test/vectors/*_test.dart (and calltype_core over its drift store) replay.
// A diff in them means the wire format or the key schedule changed. With an
// output dir the files go there instead, so a run can be diffed against the
// committed ones.
import 'dart:io';

import 'package:calltype_protocol/testing/device_list_vector_scenario.dart';
import 'package:calltype_protocol/testing/memory_vector_device.dart';
import 'package:calltype_protocol/testing/session_vector_scenario.dart';

Future<void> main(List<String> args) async {
  String out(String file) =>
      args.isEmpty ? file : '${args.first}/${file.split('/').last}';

  final session = await runSessionScenario(
    factory: memoryVectorDevice,
    draws: GeneratingDraws(),
  );
  File(out(vectorFile)).writeAsStringSync(encodeVectors(session));
  stdout.writeln(
    'wrote ${out(vectorFile)} (${(session['steps'] as List).length} steps)',
  );

  final deviceList = await buildDeviceListVectors();
  File(out(deviceListVectorFile)).writeAsStringSync(encodeVectors(deviceList));
  stdout.writeln('wrote ${out(deviceListVectorFile)}');
}
