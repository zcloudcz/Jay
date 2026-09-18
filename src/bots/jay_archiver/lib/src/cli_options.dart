/// Resolved options for a `jay_archiver` invocation. Kept as a plain value
/// type (not `Map<String, String>`) so callers get a compile error instead
/// of a runtime KeyError when a field is renamed.
class CliOptions {
  CliOptions({
    required this.apiBaseUrl,
    required this.orgId,
    required this.statePath,
    this.adminToken,
  });

  final String apiBaseUrl;
  final String orgId;
  final String statePath;
  final String? adminToken;
}

/// Merges `--flag value` pairs with their container-friendly env var
/// fallback (`JAY_API_URL`, `JAY_ORG_ID`, `JAY_STATE_DIR`) — flags win when
/// both are given. Extracted from `main()` so option resolution is testable
/// without spawning a process or setting real environment variables.
///
/// Throws [ArgumentError] naming the missing key; `main()` turns that into
/// the usage message and `exit(64)`.
CliOptions resolveOptions(
  Map<String, String> flags,
  Map<String, String> env, {
  bool requireAdminToken = false,
}) {
  String need(String flagKey, String envKey) {
    final value = flags[flagKey] ?? env[envKey];
    if (value == null || value.isEmpty) {
      throw ArgumentError('Missing required --$flagKey (or $envKey)');
    }
    return value;
  }

  final adminToken = flags['admin-token'];
  if (requireAdminToken && (adminToken == null || adminToken.isEmpty)) {
    throw ArgumentError('Missing required --admin-token');
  }

  return CliOptions(
    apiBaseUrl: need('api', 'JAY_API_URL'),
    orgId: need('org', 'JAY_ORG_ID'),
    statePath: need('state', 'JAY_STATE_DIR'),
    adminToken: adminToken,
  );
}

/// Parses `--key value` pairs from the raw argument list (unchanged
/// behaviour from the original inline `_parseOptions`).
Map<String, String> parseFlags(Iterable<String> args) {
  final map = <String, String>{};
  final list = args.toList();
  for (var i = 0; i < list.length - 1; i++) {
    if (list[i].startsWith('--')) map[list[i].substring(2)] = list[i + 1];
  }
  return map;
}
