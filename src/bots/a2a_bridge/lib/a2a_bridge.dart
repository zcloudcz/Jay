/// A2A bridge: makes any A2A agent reachable as a Jay contact.
///
/// Everything exported here is free of the bot runtime and unit-tested; the
/// runtime glue lives in `src/jay_glue.dart` and is used by `bin/`.
library;

export 'src/a2a_client.dart';
export 'src/a2a_protocol.dart';
export 'src/bridge.dart';
export 'src/commands.dart';
export 'src/config.dart';
export 'src/state_store.dart';
