import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:llm_bridge/llm_bridge.dart';

/// Scripted provider: each call takes the next script entry.
class FakeProvider implements LlmProvider {
  final calls = <({List<ChatTurn> conversation, String system})>[];
  final scripts = <Stream<String> Function()>[];

  @override
  String get label => 'Fake model';

  @override
  Stream<String> reply(List<ChatTurn> conversation, {required String system}) {
    calls.add((conversation: List.of(conversation), system: system));
    return scripts.removeAt(0)();
  }

  @override
  Future<void> close() async {}
}

class Sent {
  Sent(this.text);
  String text;
  final edits = <String>[];
}

class FakeSink implements ChatSink {
  final messages = <Sent>[];
  List<String> get texts => [for (final m in messages) m.text];

  @override
  Future<ProgressHandle> progress(String text) async {
    final s = Sent(text);
    messages.add(s);
    return _Handle(s);
  }

  @override
  Future<void> reply(String text) async => messages.add(Sent(text));

  /// Files sent, with their bytes read at send time (the bridge deletes
  /// the file right after).
  final files = <({String path, List<int> bytes})>[];

  @override
  Future<void> replyFile(String path) async =>
      files.add((path: path, bytes: await File(path).readAsBytes()));
}

class _Handle implements ProgressHandle {
  _Handle(this.sent);
  final Sent sent;
  @override
  Future<void> update(String text) async {
    sent.edits.add(text);
    sent.text = text;
  }
}

Stream<String> answer(
  List<String> pieces, {
  Duration pause = Duration.zero,
}) async* {
  for (final p in pieces) {
    if (pause > Duration.zero) await Future<void>.delayed(pause);
    yield p;
  }
}

/// Fake image API: returns [pngBytes] or throws.
class FakeGenerator implements ImageGenerator {
  FakeGenerator({this.fail = false});
  final bool fail;
  final prompts = <String>[];

  @override
  String get label => 'fake images';

  @override
  Future<Uint8List> generate(String prompt) async {
    prompts.add(prompt);
    if (fail) throw const LlmException('content policy');
    return pngBytes;
  }

  @override
  Future<void> close() async {}
}

/// Magic bytes of a PNG (all the bridge checks) plus a few body bytes.
final pngBytes = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, 1, 2, 3,
]);
