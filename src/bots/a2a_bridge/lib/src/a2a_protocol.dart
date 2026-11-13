import 'dart:convert';

/// A2A wire shapes, parsed tolerantly.
///
/// WHY one tolerant parser for two protocol versions: A2A v1.0 (Linux
/// Foundation) renamed nearly everything that v0.3 had (`TASK_STATE_WORKING`
/// vs `working`, `ROLE_USER` vs `user`, parts without `kind`, results wrapped
/// in `{task: ...}` / `{message: ...}`), and agents in the wild speak both.
/// The bridge must not care which one answered, so everything below accepts
/// either shape and never throws on unknown or missing fields.

/// The protocol generation a JSON-RPC call is made with.
enum A2aVersion {
  /// `SendMessage` / `GetTask`, `ROLE_USER`, parts `[{"text": ...}]`.
  v1,

  /// `message/send` / `tasks/get`, `user`, parts `[{"kind": "text", ...}]`.
  v03,
}

/// Task lifecycle, version independent.
enum TaskState {
  submitted,
  working,
  inputRequired,
  authRequired,
  completed,
  failed,
  canceled,
  rejected,

  /// Missing or unrecognised; treated like [working] (poll until timeout).
  unknown;

  /// No further change will ever happen to the task.
  bool get isTerminal =>
      this == completed ||
      this == failed ||
      this == canceled ||
      this == rejected;

  /// The agent waits for the user; polling would never end.
  bool get isInterrupted => this == inputRequired || this == authRequired;

  /// Polling stops here.
  bool get isSettled => isTerminal || isInterrupted;
}

/// `TASK_STATE_INPUT_REQUIRED` (v1.0) and `input-required` (v0.3) alike.
TaskState parseTaskState(Object? raw) {
  if (raw is! String) return TaskState.unknown;
  var s = raw.trim().toLowerCase();
  if (s.startsWith('task_state_')) s = s.substring('task_state_'.length);
  switch (s.replaceAll('_', '-')) {
    case 'submitted':
      return TaskState.submitted;
    case 'working':
      return TaskState.working;
    case 'input-required':
      return TaskState.inputRequired;
    case 'auth-required':
      return TaskState.authRequired;
    case 'completed':
      return TaskState.completed;
    case 'failed':
      return TaskState.failed;
    case 'canceled':
    case 'cancelled':
      return TaskState.canceled;
    case 'rejected':
      return TaskState.rejected;
    default:
      return TaskState.unknown;
  }
}

/// One advertised skill of the agent card.
class A2aSkill {
  const A2aSkill({required this.id, required this.name, this.description = ''});
  final String id;
  final String name;
  final String description;
}

/// The part of an Agent Card the bridge needs.
class AgentCard {
  const AgentCard({
    required this.name,
    required this.description,
    required this.skills,
    required this.endpoint,
    required this.preferredVersion,
    this.tenant,
  });

  final String name;
  final String description;
  final List<A2aSkill> skills;

  /// The JSON-RPC endpoint, already resolved against the card's own URL.
  /// Null when the card names none: the caller then uses the agent URL.
  final Uri? endpoint;

  /// What the card says the endpoint speaks; only a starting guess, the
  /// client still falls back on `-32601`.
  final A2aVersion preferredVersion;

  /// v1.0 multi-tenancy routing key; when present clients MUST echo it.
  final String? tenant;
}

/// Thrown when a card cannot be used at all (no JSON-RPC interface).
class AgentCardException implements Exception {
  const AgentCardException(this.message);
  final String message;
  @override
  String toString() => 'AgentCardException: $message';
}

String _str(Object? v) => v is String ? v.trim() : '';

/// `JSONRPC`, `jsonrpc`, `JSON-RPC` and `json_rpc` are all the same binding.
bool _isJsonRpc(Object? binding) =>
    _str(binding).toUpperCase().replaceAll(RegExp('[^A-Z]'), '') == 'JSONRPC';

A2aVersion _versionOf(Object? protocolVersion, A2aVersion fallback) {
  final v = _str(protocolVersion);
  if (v.isEmpty) return fallback;
  return v.startsWith('0.') ? A2aVersion.v03 : A2aVersion.v1;
}

/// Parses an Agent Card fetched from [cardUri].
///
/// Endpoint selection, in this order:
/// 1. v1.0 `supportedInterfaces[]` with `protocolBinding` JSONRPC (the
///    canonical field; `transport` accepted from pre-release drafts),
/// 2. v0.3 top-level `url` when `preferredTransport` is JSONRPC or absent
///    (JSONRPC is the v0.3 default),
/// 3. v0.3 `additionalInterfaces[]` with `transport` JSONRPC.
/// A card listing interfaces but none of them JSON-RPC is unusable: this
/// bridge only speaks JSON-RPC, and guessing another URL would POST to a
/// gRPC or REST endpoint that cannot understand it.
AgentCard parseAgentCard(Map<String, dynamic> json, Uri cardUri) {
  // v0.3 cards carry the version at top level; v1.0 per interface.
  final topVersion = _versionOf(json['protocolVersion'], A2aVersion.v1);
  Uri? endpoint;
  var version = topVersion;
  String? tenant;
  var listedAny = false;

  final interfaces = json['supportedInterfaces'];
  if (interfaces is List) {
    for (final entry in interfaces) {
      if (entry is! Map) continue;
      listedAny = true;
      final binding = entry['protocolBinding'] ?? entry['transport'];
      final url = _str(entry['url']);
      if (url.isEmpty || !_isJsonRpc(binding)) continue;
      endpoint = cardUri.resolve(url);
      version = _versionOf(entry['protocolVersion'], A2aVersion.v1);
      final t = _str(entry['tenant']);
      tenant = t.isEmpty ? null : t;
      break;
    }
  }
  if (endpoint == null) {
    final url = _str(json['url']);
    final preferred = json['preferredTransport'];
    if (url.isNotEmpty) {
      listedAny = true;
      if (preferred == null || _isJsonRpc(preferred)) {
        endpoint = cardUri.resolve(url);
        version = topVersion;
      }
    }
  }
  if (endpoint == null) {
    final extra = json['additionalInterfaces'];
    if (extra is List) {
      for (final entry in extra) {
        if (entry is! Map) continue;
        listedAny = true;
        final url = _str(entry['url']);
        if (url.isNotEmpty && _isJsonRpc(entry['transport'])) {
          endpoint = cardUri.resolve(url);
          version = topVersion;
          break;
        }
      }
    }
  }
  if (endpoint == null && listedAny) {
    throw const AgentCardException(
      'The agent card lists no JSON-RPC interface; this bridge speaks JSON-RPC only.',
    );
  }

  final skills = <A2aSkill>[];
  final rawSkills = json['skills'];
  if (rawSkills is List) {
    for (final s in rawSkills) {
      if (s is! Map) continue;
      final id = _str(s['id']);
      final name = _str(s['name']);
      if (id.isEmpty && name.isEmpty) continue;
      skills.add(
        A2aSkill(
          id: id.isEmpty ? name : id,
          name: name.isEmpty ? id : name,
          description: _str(s['description']),
        ),
      );
    }
  }
  return AgentCard(
    name: _str(json['name']),
    description: _str(json['description']),
    skills: skills,
    endpoint: endpoint,
    preferredVersion: version,
    tenant: tenant,
  );
}

/// Builds the `message` object of a send request.
///
/// [leadingTexts] become text parts BEFORE [text] (group topic and group
/// context, spec 2026-11-13-group-topics); [metadata] is the message's
/// optional `metadata` object (both A2A versions have it).
Map<String, dynamic> buildUserMessage(
  A2aVersion version, {
  required String messageId,
  required String text,
  String? contextId,
  String? taskId,
  List<String> leadingTexts = const [],
  Map<String, Object?>? metadata,
}) {
  Map<String, dynamic> part(String t) =>
      version == A2aVersion.v1 ? {'text': t} : {'kind': 'text', 'text': t};
  return {
    if (version == A2aVersion.v03) 'kind': 'message',
    'messageId': messageId,
    'role': version == A2aVersion.v1 ? 'ROLE_USER' : 'user',
    'parts': [for (final t in leadingTexts) part(t), part(text)],
    'contextId': ?contextId,
    'taskId': ?taskId,
    'metadata': ?metadata,
  };
}

/// A send result: either a direct [A2aMessage] or an [A2aTask].
sealed class A2aResult {
  const A2aResult();
  String? get contextId;
}

class A2aMessage extends A2aResult {
  const A2aMessage({required this.text, this.contextId});
  final String text;
  @override
  final String? contextId;
}

class A2aTask extends A2aResult {
  const A2aTask({
    required this.id,
    required this.state,
    required this.statusText,
    required this.artifactText,
    this.contextId,
  });

  final String id;
  @override
  final String? contextId;
  final TaskState state;

  /// Text of `status.message` (progress note, question, error reason).
  final String statusText;

  /// Text of all artifacts, in order.
  final String artifactText;

  /// What the user should read: the status note and the artifacts.
  ///
  /// WHY the containment check: some agents (Hermes' A2A plugin among them)
  /// put the same final answer into BOTH `status.message` and an artifact;
  /// printing it twice would look broken.
  String get text {
    final s = statusText.trim();
    final a = artifactText.trim();
    if (a.isEmpty) return s;
    if (s.isEmpty || a.contains(s)) return a;
    if (s.contains(a)) return s;
    return '$s\n\n$a';
  }
}

/// Unwraps v1.0 `{task: ...}` / `{message: ...}` and accepts the bare v0.3
/// (and legacy) payloads. Null when [result] is neither.
A2aResult? parseSendResult(Object? result) {
  if (result is! Map) return null;
  final task = result['task'];
  if (task is Map) return parseTask(task);
  final message = result['message'];
  if (message is Map && result['status'] == null) return _parseMessage(message);
  final kind = result['kind'];
  if (kind == 'task') return parseTask(result);
  if (kind == 'message') return _parseMessage(result);
  if (result['status'] is Map && result['id'] != null) return parseTask(result);
  if (result['parts'] is List) return _parseMessage(result);
  return null;
}

A2aMessage _parseMessage(Map<dynamic, dynamic> m) => A2aMessage(
  text: partsText(m['parts']),
  contextId: _nonEmpty(m['contextId']),
);

String? _nonEmpty(Object? v) {
  final s = _str(v);
  return s.isEmpty ? null : s;
}

/// A Task (either version). GetTask results are bare tasks in both, but a
/// wrapped `{task: ...}` is accepted too.
A2aTask parseTask(Map<dynamic, dynamic> t) {
  final inner = t['task'];
  if (inner is Map && t['status'] == null) return parseTask(inner);
  final status = t['status'];
  var statusText = '';
  var state = TaskState.unknown;
  if (status is Map) {
    state = parseTaskState(status['state']);
    final message = status['message'];
    if (message is Map) statusText = partsText(message['parts']);
  }
  final artifacts = <String>[];
  final rawArtifacts = t['artifacts'];
  if (rawArtifacts is List) {
    for (final a in rawArtifacts) {
      if (a is! Map) continue;
      final text = partsText(a['parts']);
      if (text.isNotEmpty) artifacts.add(text);
    }
  }
  return A2aTask(
    id: _str(t['id']),
    contextId: _nonEmpty(t['contextId']),
    state: state,
    statusText: statusText,
    artifactText: artifacts.join('\n\n'),
  );
}

/// Readable text of a part list. Text parts verbatim; file parts as a note
/// with their URL (raw bytes are never decoded: the bridge relays text
/// only); data parts as compact JSON.
String partsText(Object? parts) {
  if (parts is! List) return '';
  final chunks = <String>[];
  for (final part in parts) {
    if (part is! Map) continue;
    final text = part['text'];
    if (text is String) {
      chunks.add(text);
      continue;
    }
    // v1.0 file part: url | raw + filename + mediaType.
    final url = _str(part['url']);
    final v03File = part['file'];
    if (url.isNotEmpty) {
      chunks.add(_fileNote(_str(part['filename']), url));
    } else if (v03File is Map && _str(v03File['uri']).isNotEmpty) {
      chunks.add(_fileNote(_str(v03File['name']), _str(v03File['uri'])));
    } else if (part['raw'] is String ||
        (v03File is Map && v03File['bytes'] is String)) {
      final name = _str(part['filename']).isNotEmpty
          ? _str(part['filename'])
          : (v03File is Map ? _str(v03File['name']) : '');
      chunks.add(_fileNote(name, '(inline file, not shown)'));
    } else if (part.containsKey('data')) {
      chunks.add(jsonEncode(part['data']));
    }
  }
  return chunks.join('\n').trim();
}

String _fileNote(String name, String body) =>
    name.isEmpty ? '[file] $body' : '[file: $name] $body';
