/// What one Hermes turn reports while it runs, parsed from the SSE stream of
/// `POST /api/sessions/{id}/chat/stream` (Hermes `api_server.py`,
/// `_handle_session_chat_stream`). Only the events the bridge acts on are
/// modelled; everything else (run.started, message.started, tool.progress
/// thinking, assistant.commentary, run.completed, keepalives) is skipped.
sealed class HermesEvent {
  const HermesEvent();
}

/// `assistant.delta {message_id, delta}`: a piece of the answer text.
final class HermesDelta extends HermesEvent {
  const HermesDelta(this.text);
  final String text;
}

/// `tool.started` / `tool.completed` / `tool.failed`
/// `{message_id, tool_name, preview, args}`.
final class HermesToolEvent extends HermesEvent {
  const HermesToolEvent({
    required this.phase,
    required this.toolName,
    this.preview,
  });

  /// `started`, `completed` or `failed`.
  final String phase;
  final String toolName;
  final String? preview;
}

/// `approval.request`: a dangerous command waits for a human decision,
/// answered with `POST /v1/runs/{runId}/approval {choice, request_id}`.
final class HermesApprovalRequest extends HermesEvent {
  const HermesApprovalRequest({
    required this.runId,
    required this.requestId,
    required this.command,
    this.description = '',
    this.choices = const ['once', 'session', 'deny'],
  });

  final String runId;
  final String requestId;

  /// Already redacted by Hermes before it leaves the server.
  final String command;
  final String description;

  /// What Hermes accepts for this request (e.g. no `session` for a
  /// smart-denied command).
  final List<String> choices;
}

/// `assistant.completed {content}`: the final answer of the turn.
final class HermesCompleted extends HermesEvent {
  const HermesCompleted(this.content);
  final String content;
}

/// `error {message}`: the turn failed on the Hermes side.
final class HermesError extends HermesEvent {
  const HermesError(this.message);
  final String message;
}

/// A turn that ended with [HermesError].
class HermesTurnException implements Exception {
  const HermesTurnException(this.message);
  final String message;
  @override
  String toString() => 'HermesTurnException: $message';
}

/// Turns one SSE frame (`event` name + decoded `data` JSON) into an event,
/// or null for frames the bridge ignores or cannot read.
HermesEvent? hermesEventFromSse(String name, Object? data) {
  final map = data is Map ? data : const {};
  String? str(String key) => map[key] is String ? map[key] as String : null;
  switch (name) {
    case 'assistant.delta':
      final delta = str('delta');
      return delta == null || delta.isEmpty ? null : HermesDelta(delta);
    case 'tool.started' || 'tool.completed' || 'tool.failed':
      return HermesToolEvent(
        phase: name.substring('tool.'.length),
        toolName: str('tool_name') ?? 'tool',
        preview: str('preview'),
      );
    case 'approval.request':
      final runId = str('run_id');
      final requestId = str('request_id');
      if (runId == null || requestId == null) return null;
      final choices = map['choices'];
      return HermesApprovalRequest(
        runId: runId,
        requestId: requestId,
        command: str('command') ?? '',
        description: str('description') ?? '',
        choices: choices is List
            ? [
                for (final c in choices)
                  if (c is String) c,
              ]
            : const ['once', 'session', 'deny'],
      );
    case 'assistant.completed':
      return HermesCompleted(str('content') ?? '');
    case 'error':
      return HermesError(str('message') ?? 'unknown error');
  }
  return null;
}
