import 'dart:async';
import 'dart:typed_data';

import 'package:calltype/features/chat/attachment_media.dart';
import 'package:calltype/features/chat/message_input.dart';
import 'package:calltype/features/media/voice_composer.dart';
import 'package:calltype/features/media/voice_recorder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/localized_app.dart';

class FakeVoiceRecorder implements VoiceRecorder {
  bool permission = true;
  int starts = 0;
  int stops = 0;
  int cancels = 0;
  final levelSink = StreamController<double>.broadcast();

  @override
  Future<bool> hasPermission() async => permission;
  @override
  Future<void> start() async => starts++;
  @override
  Stream<double> get levels => levelSink.stream;
  @override
  Future<RecordedVoice?> stop() async {
    stops++;
    return RecordedVoice(
      file: PickedMedia.bytes(
        'voice.m4a',
        Uint8List(100),
        mimeType: 'audio/mp4',
      ),
      mime: 'audio/mp4',
    );
  }

  @override
  Future<void> cancel() async => cancels++;
  @override
  Future<void> dispose() async {}
}

/// Contract 4.2: hold to record, slide to cancel, too short is dropped,
/// release sends; driven by a fake recorder.
void main() {
  late FakeVoiceRecorder recorder;
  late List<VoiceClip> sent;
  final original = VoiceRecorder.create;

  setUp(() {
    recorder = FakeVoiceRecorder();
    sent = [];
    VoiceRecorder.create = () => recorder;
  });
  tearDown(() => VoiceRecorder.create = original);

  Future<void> pumpInput(WidgetTester tester) => tester.pumpWidget(
    localizedApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: MessageInput(
            onSend: (_) async {},
            onVoice: (clip) async => sent.add(clip),
          ),
        ),
      ),
    ),
  );

  final mic = find.byKey(const ValueKey('voice-record'));
  final bar = find.byType(VoiceRecordingBar);

  testWidgets('idle: the mic replaces send while the field is empty', (
    tester,
  ) async {
    await pumpInput(tester);
    expect(mic, findsOneWidget);
    expect(find.byTooltip(l10nEn.chatInputSend), findsNothing);
    await tester.enterText(find.byType(TextField), 'hi');
    await tester.pump();
    expect(mic, findsNothing);
    expect(find.byTooltip(l10nEn.chatInputSend), findsOneWidget);
  });

  testWidgets('recording shows the timer and "slide to cancel"; release '
      'after 2 s sends duration and a 64-bar waveform', (tester) async {
    await pumpInput(tester);
    final gesture = await tester.startGesture(tester.getCenter(mic));
    await tester.pump();
    expect(recorder.starts, 1);
    expect(bar, findsOneWidget);
    expect(find.text(l10nEn.voiceSlideToCancel), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    for (var i = 0; i < 20; i++) {
      recorder.levelSink.add(i / 20);
    }
    await tester.pump(const Duration(milliseconds: 2000));
    expect(find.text('0:02'), findsOneWidget);
    await gesture.up();
    await tester.pump();
    await tester.pump();
    expect(recorder.stops, 1);
    expect(sent, hasLength(1));
    expect(sent.single.durationMs, 2000);
    expect(sent.single.waveform, hasLength(64));
    expect(bar, findsNothing);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('sliding towards the start edge cancels', (tester) async {
    await pumpInput(tester);
    final gesture = await tester.startGesture(tester.getCenter(mic));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();
    expect(bar, findsOneWidget, reason: 'not past the threshold yet');
    await gesture.moveBy(const Offset(-80, 0));
    await tester.pump();
    expect(recorder.cancels, 1);
    expect(bar, findsNothing);
    await gesture.up();
    await tester.pump();
    expect(sent, isEmpty);
    expect(recorder.stops, 0);
  });

  testWidgets('shorter than 1 s is discarded with the hint', (tester) async {
    await pumpInput(tester);
    final gesture = await tester.startGesture(tester.getCenter(mic));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.up();
    await tester.pump();
    await tester.pump();
    expect(sent, isEmpty);
    expect(recorder.cancels, 1);
    expect(find.text(l10nEn.voiceHoldToRecord), findsOneWidget);
  });

  testWidgets('a denied microphone points to Settings', (tester) async {
    recorder.permission = false;
    await pumpInput(tester);
    final gesture = await tester.startGesture(tester.getCenter(mic));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(recorder.starts, 0);
    expect(find.text(l10nEn.voiceMicrophoneDenied), findsOneWidget);
  });

  testWidgets('30 minutes stop and send on their own', (tester) async {
    await pumpInput(tester);
    final gesture = await tester.startGesture(tester.getCenter(mic));
    await tester.pump();
    await tester.pump(const Duration(minutes: 30));
    await tester.pump();
    expect(sent, hasLength(1));
    expect(sent.single.durationMs, const Duration(minutes: 30).inMilliseconds);
    await gesture.up();
    await tester.pump();
    expect(sent, hasLength(1));
  });
}
