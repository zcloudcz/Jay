/// LLM bridge: a Jay contact answered by Anthropic, an OpenAI-compatible
/// API, or the owner's own Claude Code / Codex CLI.
///
/// Everything exported here is unit-tested; `src/jay_glue.dart` adds the
/// bot runtime and is used by `bin/`.
library;

export 'src/access.dart';
export 'src/bridge.dart';
export 'src/cli_providers.dart';
export 'src/config.dart';
export 'src/factory.dart';
export 'src/history_store.dart';
export 'src/http_providers.dart';
export 'src/provider.dart';
