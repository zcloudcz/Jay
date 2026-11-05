/// Environment configuration of the bridge (contract section 7), parsed in
/// pure Dart so the fail-closed rules are unit-tested.
library;

/// A configuration error: the process exits with EX_CONFIG and this text.
class ConfigException implements Exception {
  const ConfigException(this.message);
  final String message;
  @override
  String toString() => message;
}

final _handlePattern = RegExp(r'^CT-[A-Z0-9]{4}-[A-Z0-9]{4}$');

class BridgeConfig {
  const BridgeConfig({
    required this.apiUrl,
    required this.storePath,
    required this.allowedHandles,
    required this.agentUrl,
    required this.statePath,
    this.endpointUrl,
    this.token,
    this.displayName,
    this.timeout = const Duration(seconds: 300),
    this.pollInterval = const Duration(seconds: 3),
  });

  final String apiUrl;
  final String storePath;
  final Set<String> allowedHandles;
  final String agentUrl;
  final String? endpointUrl;
  final String? token;

  /// Null = use the card's `name`.
  final String? displayName;
  final Duration timeout;
  final Duration pollInterval;
  final String statePath;

  /// Reads the environment; throws [ConfigException] on anything unusable.
  ///
  /// WHY refuse to start on an empty `ALLOWED_HANDLES` (stricter than the
  /// Hermes bridge, which runs and answers nobody): this bridge has no other
  /// purpose than relaying owners' messages, and the agent behind it may hold
  /// tools and data. A running bot that silently ignores everyone looks like
  /// a bug; a refused start with a clear message is the safer failure.
  static BridgeConfig fromEnvironment(Map<String, String> env) {
    String? opt(String name) {
      final v = env[name]?.trim() ?? '';
      return v.isEmpty ? null : v;
    }

    String required(String name) =>
        opt(name) ??
        (throw ConfigException('Missing required environment variable $name.'));

    Duration seconds(String name, int fallback) {
      final raw = opt(name);
      if (raw == null) return Duration(seconds: fallback);
      final v = int.tryParse(raw);
      if (v == null || v <= 0) {
        throw ConfigException('$name must be a positive integer, got "$raw".');
      }
      return Duration(seconds: v);
    }

    final agentUrl = required('A2A_AGENT_URL');
    final agent = Uri.tryParse(agentUrl);
    if (agent == null ||
        !(agent.scheme == 'http' || agent.scheme == 'https') ||
        agent.host.isEmpty) {
      throw ConfigException(
        'A2A_AGENT_URL must be an http(s) URL, got "$agentUrl".',
      );
    }
    final endpointUrl = opt('A2A_ENDPOINT_URL');
    if (endpointUrl != null) {
      final e = Uri.tryParse(endpointUrl);
      if (e == null || !(e.scheme == 'http' || e.scheme == 'https')) {
        throw ConfigException('A2A_ENDPOINT_URL must be an http(s) URL.');
      }
    }
    final storePath = opt('BOT_STORE_PATH') ?? '/data/bot.store';
    return BridgeConfig(
      apiUrl: required('CALLTYPE_API_URL'),
      storePath: storePath,
      allowedHandles: parseAllowedHandles(env['ALLOWED_HANDLES']),
      agentUrl: agentUrl,
      endpointUrl: endpointUrl,
      token: opt('A2A_TOKEN'),
      displayName: opt('BOT_DISPLAY_NAME'),
      timeout: seconds('A2A_TIMEOUT_SECONDS', 300),
      pollInterval: seconds('A2A_POLL_SECONDS', 3),
      statePath: opt('A2A_STATE_PATH') ?? '$storePath.a2a.json',
    );
  }
}

/// `ALLOWED_HANDLES` -> upper-case handle set. Throws when empty or when an
/// entry is not a `CT-XXXX-XXXX` handle (a typo must not silently shrink
/// the list to "nobody" or, worse, be mistaken for someone else).
Set<String> parseAllowedHandles(String? raw) {
  final handles = <String>{};
  for (final part in (raw ?? '').split(',')) {
    final h = part.trim().toUpperCase();
    if (h.isEmpty) continue;
    if (!_handlePattern.hasMatch(h)) {
      throw ConfigException(
        'ALLOWED_HANDLES: "$h" is not a Jay handle (CT-XXXX-XXXX).',
      );
    }
    handles.add(h);
  }
  if (handles.isEmpty) {
    throw const ConfigException(
      'ALLOWED_HANDLES is empty: refusing to start. Set it to your own Jay '
      'handle(s), e.g. ALLOWED_HANDLES=CT-XXXX-XXXX (Jay: Settings -> Identity).',
    );
  }
  return handles;
}

/// Resolves handles to device ids once at start (incoming messages carry
/// ids, not handles). Unknown handles are logged and skipped; if NONE
/// resolves the start is refused, same fail-closed rule as an empty list.
Future<Map<String, String>> resolveAllowedHandles(
  Set<String> handles,
  Future<String?> Function(String handle) lookup, {
  void Function(String) log = _noLog,
}) async {
  final ids = <String, String>{}; // device id (lower-case) -> handle
  for (final handle in handles) {
    final id = await lookup(handle);
    if (id == null) {
      log('ALLOWED_HANDLES: $handle is unknown to the server, ignored.');
    } else {
      ids[id.toLowerCase()] = handle;
    }
  }
  if (ids.isEmpty) {
    throw const ConfigException(
      'ALLOWED_HANDLES: none of the handles is known to the server; refusing '
      'to start (the bot would answer nobody).',
    );
  }
  return ids;
}

void _noLog(String _) {}
