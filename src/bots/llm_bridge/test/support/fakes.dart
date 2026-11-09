import 'dart:async';

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
