import 'dart:async';

import 'package:calltype_bot/calltype_bot.dart';

import 'hermes_events.dart';

/// When and how often the bridge shows "working..." for a slow turn
/// (env `PROGRESS_AFTER_SECONDS`, `PROGRESS_EDIT_SECONDS`, `PROGRESS_MAX_EDITS`).
class ProgressSettings {
  const ProgressSettings({
    this.after = const Duration(seconds: 8),
    this.editInterval = const Duration(seconds: 5),
    this.maxEdits = 30,
  });

  /// No progress message at all.
  static const never = ProgressSettings(after: Duration.zero);

  /// Show a progress message when the answer is not there after this long.
  /// [Duration.zero] = never.
  final Duration after;

  /// Minimum time between two progress edits.
  final Duration editInterval;

  /// Progress edits per turn; after that the message stays as it is until
  /// the final answer replaces it.
  final int maxEdits;
}

/// The progress message of ONE turn: posted after [ProgressSettings.after],
/// edited (throttled) as tools run, finally turned into the answer.
///
/// WHY throttled and capped: every edit is a full message to every device
/// of every recipient, and an old app keeps an unknown `edit` queued until
/// the server's TTL. A chatty tool loop must not become hundreds of
/// messages.
class ProgressReporter {
  ProgressReporter({
    required ProgressSettings settings,
    required Future<BotSentMessage> Function(String text) post,
    void Function(String line)? log,
  }) : _settings = settings,
       _post = post,
       _log = log ?? ((_) {});

  final ProgressSettings _settings;
  final Future<BotSentMessage> Function(String text) _post;
  final void Function(String) _log;

  Timer? _showTimer;
  Timer? _editTimer;
  BotSentMessage? _message;
  DateTime? _lastEdit;
  int _edits = 0;
  int _steps = 0;
  String? _status;
  bool _dirty = false;
  bool _finished = false;

  /// Every post/edit runs through this chain so they never overtake each
  /// other (an older progress text must not land after the final answer).
  Future<void> _ops = Future.value();

  void start() {
    if (_settings.after <= Duration.zero) return;
    _showTimer = Timer(_settings.after, () => _enqueue(_show));
  }

  /// A tool started/finished: the next (throttled) edit shows it.
  void tool(HermesToolEvent event) {
    if (_finished) return;
    if (event.phase == 'started') _steps++;
    final preview = _short(event.preview ?? '', 80);
    _status = switch (event.phase) {
      'failed' => '${event.toolName} failed',
      _ => preview.isEmpty ? event.toolName : '${event.toolName}: $preview',
    };
    _dirty = true;
    if (_message != null) _scheduleEdit();
  }

  String get _text {
    final status = _status;
    if (status == null) return 'Working on it...';
    return 'Working on it... (step $_steps)\n$status';
  }

  Future<void> _show() async {
    if (_finished || _message != null) return;
    final posted = _text;
    _message = await _post(posted);
    _lastEdit = DateTime.now();
    // A tool event that arrived while the post was in flight is not in it.
    _dirty = _text != posted;
    if (_dirty) _scheduleEdit();
  }

  void _scheduleEdit() {
    if (_editTimer != null || _edits >= _settings.maxEdits) return;
    final since = DateTime.now().difference(_lastEdit ?? DateTime(0));
    final wait = _settings.editInterval - since;
    _editTimer = Timer(wait.isNegative ? Duration.zero : wait, () {
      _editTimer = null;
      _enqueue(_editNow);
    });
  }

  Future<void> _editNow() async {
    final message = _message;
    if (_finished || message == null || !_dirty) return;
    if (_edits >= _settings.maxEdits) return;
    _dirty = false;
    _edits++;
    _lastEdit = DateTime.now();
    await message.edit(_text);
  }

  void _enqueue(Future<void> Function() op) {
    _ops = _ops.then((_) => op()).catchError((Object e) {
      // A lost progress update is cosmetic; the final answer still goes out.
      _log('Progress update failed: $e');
    });
  }

  /// Ends the progress. If a progress message was shown it becomes [text]
  /// (returns true); otherwise nothing is sent (returns false) and the caller
  /// replies normally. Only the first call does anything.
  Future<bool> finish(String text) async {
    if (_finished) return false;
    _finished = true;
    _showTimer?.cancel();
    _editTimer?.cancel();
    await _ops;
    final message = _message;
    if (message == null) return false;
    await message.edit(text);
    return true;
  }

  /// Stops all timers without touching the message.
  void cancel() {
    _finished = true;
    _showTimer?.cancel();
    _editTimer?.cancel();
  }
}

String _short(String text, int max) {
  final line = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return line.runes.length <= max
      ? line
      : '${String.fromCharCodes(line.runes.take(max - 3))}...';
}
