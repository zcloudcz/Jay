import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import 'media_message.dart';
import 'voice_recorder.dart';

/// A finished voice message: the file plus what the bubble shows before
/// anyone downloads it.
class VoiceClip {
  const VoiceClip({
    required this.recording,
    required this.durationMs,
    required this.waveform,
  });
  final RecordedVoice recording;
  final int durationMs;
  final List<int> waveform;
}

enum VoiceRecordState { idle, starting, recording }

/// Why a press did not produce a voice message.
enum VoiceOutcome { cancelled, tooShort, denied, failed }

/// Hold-to-record logic (contract 4.2), independent of the widgets so it is
/// testable with a fake [VoiceRecorder]: press starts, release sends,
/// sliding [cancelDistance] towards the start edge cancels, anything
/// shorter than [minDuration] is dropped, [maxDuration] stops and sends.
///
/// Time is counted with a periodic timer, not a clock, so widget tests
/// advance it with `tester.pump(duration)`.
class VoiceRecordController extends ChangeNotifier {
  VoiceRecordController({
    required this.onRecorded,
    required this.onOutcome,
    VoiceRecorder Function()? recorder,
    this.minDuration = const Duration(seconds: 1),
    this.maxDuration = const Duration(minutes: 30),
    this.cancelDistance = 96,
  }) : _create = recorder ?? VoiceRecorder.create;

  final Future<void> Function(VoiceClip clip) onRecorded;
  final void Function(VoiceOutcome outcome) onOutcome;
  final VoiceRecorder Function() _create;
  final Duration minDuration;
  final Duration maxDuration;
  final double cancelDistance;

  static const _tick = Duration(milliseconds: 100);

  VoiceRecorder? _recorder;
  VoiceRecordState _state = VoiceRecordState.idle;
  VoiceRecordState get state => _state;
  Duration _elapsed = Duration.zero;
  Duration get elapsed => _elapsed;

  /// How far (logical px, towards the start edge) the finger has slid.
  double _slide = 0;
  double get slide => _slide;
  final _samples = <double>[];
  Timer? _timer;
  StreamSubscription<double>? _levels;
  bool _released = false;

  /// The latest input level, for the pulsing indicator.
  double get level => _samples.isEmpty ? 0 : _samples.last;

  Future<void> press() async {
    if (_state != VoiceRecordState.idle) return;
    _released = false;
    _slide = 0;
    _elapsed = Duration.zero;
    _samples.clear();
    _state = VoiceRecordState.starting;
    notifyListeners();
    final recorder = _recorder ??= _create();
    try {
      if (!await recorder.hasPermission()) {
        _reset();
        onOutcome(VoiceOutcome.denied);
        return;
      }
      if (_released) {
        // Let go while the permission prompt was up: a tap, not a hold.
        _reset();
        onOutcome(VoiceOutcome.tooShort);
        return;
      }
      await recorder.start();
    } catch (_) {
      _reset();
      onOutcome(VoiceOutcome.failed);
      return;
    }
    unawaited(HapticFeedback.mediumImpact());
    _levels = recorder.levels.listen(_samples.add, onError: (Object _) {});
    _state = VoiceRecordState.recording;
    _timer = Timer.periodic(_tick, (_) {
      _elapsed += _tick;
      notifyListeners();
      if (_elapsed >= maxDuration) unawaited(release());
    });
    notifyListeners();
    if (_released) await release();
  }

  /// [distance] = how far the pointer moved towards the start edge.
  void drag(double distance) {
    if (_state != VoiceRecordState.recording) return;
    _slide = distance < 0 ? 0 : distance;
    if (_slide >= cancelDistance) {
      unawaited(HapticFeedback.selectionClick());
      unawaited(cancel());
      return;
    }
    notifyListeners();
  }

  Future<void> cancel() async {
    _released = true;
    if (_state != VoiceRecordState.recording) return;
    final recorder = _recorder!;
    _reset();
    try {
      await recorder.cancel();
    } catch (_) {}
    onOutcome(VoiceOutcome.cancelled);
  }

  Future<void> release() async {
    _released = true;
    if (_state != VoiceRecordState.recording) return;
    final recorder = _recorder!;
    final elapsed = _elapsed;
    final samples = List<double>.of(_samples);
    _reset();
    if (elapsed < minDuration) {
      try {
        await recorder.cancel();
      } catch (_) {}
      onOutcome(VoiceOutcome.tooShort);
      return;
    }
    RecordedVoice? recording;
    try {
      recording = await recorder.stop();
    } catch (_) {
      recording = null;
    }
    if (recording == null) {
      onOutcome(VoiceOutcome.failed);
      return;
    }
    await onRecorded(
      VoiceClip(
        recording: recording,
        durationMs: elapsed.inMilliseconds,
        waveform: samples.isEmpty ? const [] : reduceWaveform(samples),
      ),
    );
  }

  void _reset() {
    _timer?.cancel();
    _timer = null;
    unawaited(_levels?.cancel());
    _levels = null;
    _state = VoiceRecordState.idle;
    _slide = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_levels?.cancel());
    final recorder = _recorder;
    if (recorder != null) {
      unawaited(() async {
        try {
          if (_state == VoiceRecordState.recording) await recorder.cancel();
          await recorder.dispose();
        } catch (_) {}
      }());
    }
    super.dispose();
  }
}

/// The mic button: hold to record. Raw pointer events instead of a
/// long-press recognizer so recording starts on touch down and the slide
/// is tracked from the very first move. Stateful: the press origin must
/// survive the rebuilds the recording itself triggers.
class VoiceRecordButton extends StatefulWidget {
  const VoiceRecordButton({super.key, required this.controller});
  final VoiceRecordController controller;

  @override
  State<VoiceRecordButton> createState() => _VoiceRecordButtonState();
}

class _VoiceRecordButtonState extends State<VoiceRecordButton> {
  Offset? _origin;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return Listener(
      key: const ValueKey('voice-record'),
      onPointerDown: (event) {
        _origin = event.position;
        unawaited(controller.press());
      },
      onPointerMove: (event) {
        final start = _origin;
        if (start == null) return;
        final dx = event.position.dx - start.dx;
        controller.drag(rtl ? dx : -dx);
      },
      onPointerUp: (_) {
        _origin = null;
        unawaited(controller.release());
      },
      onPointerCancel: (_) {
        _origin = null;
        unawaited(controller.cancel());
      },
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final active = controller.state != VoiceRecordState.idle;
          final scheme = Theme.of(context).colorScheme;
          return Tooltip(
            message: context.l10n.voiceRecordTooltip,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: EdgeInsets.all(active ? 14 : 8),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: active ? scheme.primary : Colors.transparent,
              ),
              child: Icon(
                Icons.mic_rounded,
                color: active ? scheme.onPrimary : scheme.primary,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Replaces the text field while recording: a red dot, the timer and the
/// "slide to cancel" hint, which fades as the finger approaches the cancel
/// distance.
class VoiceRecordingBar extends StatelessWidget {
  const VoiceRecordingBar({super.key, required this.controller});
  final VoiceRecordController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final scheme = Theme.of(context).colorScheme;
      final fade = (1 - controller.slide / controller.cancelDistance).clamp(
        0.2,
        1.0,
      );
      return Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          children: [
            Icon(Icons.fiber_manual_record, color: scheme.error, size: 14),
            const SizedBox(width: 8),
            Text(
              formatMediaDuration(controller.elapsed.inMilliseconds),
              key: const ValueKey('voice-timer'),
            ),
            const Spacer(),
            Opacity(
              opacity: fade,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.chevron_left_rounded, size: 18),
                  Text(context.l10n.voiceSlideToCancel),
                ],
              ),
            ),
            SizedBox(width: controller.slide.clamp(0, 60)),
          ],
        ),
      );
    },
  );
}
