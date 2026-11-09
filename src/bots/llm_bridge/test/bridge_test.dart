import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:llm_bridge/llm_bridge.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  late Directory dir;
  late FakeProvider provider;
  late HistoryStore store;
  final key = base64Decode(base64Encode(List.filled(32, 1)));
  final sleeps = <Duration>[];

  Future<HistoryStore> openStore({int cap = 20}) =>
      HistoryStore.open('${dir.path}/bot.store.llm', key, cap: cap);

  LlmBridge bridge({
    Duration timeout = const Duration(seconds: 5),
    Duration progressAfter = Duration.zero,
    Duration editInterval = const Duration(milliseconds: 20),
    int maxEdits = 30,
  }) => LlmBridge(
    provider: provider,
    history: store,
    displayName: 'Pepa',
    systemPrompt: 'You are Pepa.',
    timeout: timeout,
    progressAfter: progressAfter,
    editInterval: editInterval,
    maxProgressEdits: maxEdits,
    sleep: (d) async => sleeps.add(d),
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('llm_bridge_test');
    provider = FakeProvider();
    store = await openStore();
    sleeps.clear();
  });
  tearDown(() => dir.delete(recursive: true));

  test('answer is posted and both turns are remembered', () async {
    provider.scripts.add(() => answer(['Ahoj', ', Martine.']));
    final sink = FakeSink();
    await bridge().handle(conversationId: 'C1', text: 'Ahoj', sink: sink);
    expect(sink.texts, ['Ahoj, Martine.']);
    expect(provider.calls.single.system, 'You are Pepa.');
    expect(provider.calls.single.conversation, [const ChatTurn.user('Ahoj')]);
    expect(await store.history('c1'), [
      const ChatTurn.user('Ahoj'),
      const ChatTurn.assistant('Ahoj, Martine.'),
    ]);
  });

  test('history is sent with the next message and capped', () async {
    store = await openStore(cap: 4);
    for (var i = 1; i <= 3; i++) {
      provider.scripts.add(() => answer(['a$i']));
      await bridge().handle(conversationId: 'c', text: 'q$i', sink: FakeSink());
    }
    expect(provider.calls.last.conversation, [
      const ChatTurn.user('q1'),
      const ChatTurn.assistant('a1'),
      const ChatTurn.user('q2'),
      const ChatTurn.assistant('a2'),
      const ChatTurn.user('q3'),
    ]);
    // Cap 4: the oldest exchange is gone.
    expect(await store.history('c'), [
      const ChatTurn.user('q2'),
      const ChatTurn.assistant('a2'),
      const ChatTurn.user('q3'),
      const ChatTurn.assistant('a3'),
    ]);
    // Other conversations are separate.
    expect(await store.history('other'), isEmpty);
  });

  test('history survives a restart and is encrypted on disk', () async {
    provider.scripts.add(() => answer(['tajná odpověď']));
    await bridge().handle(
      conversationId: 'c',
      text: 'tajná otázka',
      sink: FakeSink(),
    );
    final reopened = await openStore();
    expect((await reopened.history('c')).last.text, 'tajná odpověď');
    final raw = await File('${dir.path}/bot.store.llm').readAsBytes();
    expect(utf8.decode(raw, allowMalformed: true), isNot(contains('tajn')));
  });

  test('/new forgets the chat without calling the model', () async {
    provider.scripts.add(() => answer(['a']));
    await bridge().handle(conversationId: 'c', text: 'q', sink: FakeSink());
    final sink = FakeSink();
    await bridge().handle(conversationId: 'c', text: '/new', sink: sink);
    expect(sink.texts.single, BridgeTexts.reset);
    expect(await store.history('c'), isEmpty);
    expect(provider.calls, hasLength(1));
  });

  test('/help@HANDLE and /start answer locally', () async {
    for (final cmd in ['/help@CT-BOT1-0001', '/start abc']) {
      final sink = FakeSink();
      await bridge().handle(conversationId: 'c', text: cmd, sink: sink);
      expect(sink.texts.single, allOf(contains('Pepa'), contains('/new')));
    }
    expect(provider.calls, isEmpty);
  });

  test('group messages are labelled with the sender handle', () async {
    provider.scripts.add(() => answer(['ok']));
    await bridge().handle(
      conversationId: 'g',
      text: '@Pepa shrň to',
      sink: FakeSink(),
      senderLabel: 'CT-AAAA-0001',
    );
    expect(
      provider.calls.single.conversation.single.text,
      '[from CT-AAAA-0001] @Pepa shrň to',
    );
  });

  test(
    'provider error -> apology with the reason, nothing remembered',
    () async {
      provider.scripts.add(
        () => Stream.error(const LlmException('model is down', status: 500)),
      );
      final sink = FakeSink();
      await bridge().handle(conversationId: 'c', text: 'q', sink: sink);
      expect(sink.texts.single, 'Sorry, I could not answer: model is down');
      expect(await store.history('c'), isEmpty);
    },
  );

  test('auth error tells the owner to fix the key', () async {
    provider.scripts.add(
      () => Stream.error(const LlmException('invalid x-api-key', status: 401)),
    );
    final sink = FakeSink();
    await bridge().handle(conversationId: 'c', text: 'q', sink: sink);
    expect(sink.texts.single, allOf(contains('HTTP 401'), contains('API key')));
  });

  test('429 is retried once after retry-after, then answered', () async {
    provider.scripts
      ..add(
        () => Stream.error(
          const LlmException(
            'rate',
            status: 429,
            retryAfter: Duration(seconds: 3),
          ),
        ),
      )
      ..add(() => answer(['po čekání']));
    final sink = FakeSink();
    await bridge().handle(conversationId: 'c', text: 'q', sink: sink);
    expect(sleeps, [const Duration(seconds: 3)]);
    expect(provider.calls, hasLength(2));
    expect(sink.texts.single, 'po čekání');
  });

  test('a second 429 is not retried again', () async {
    for (var i = 0; i < 2; i++) {
      provider.scripts.add(
        () => Stream.error(const LlmException('rate', status: 429)),
      );
    }
    final sink = FakeSink();
    await bridge(
      timeout: const Duration(minutes: 1),
    ).handle(conversationId: 'c', text: 'q', sink: sink);
    expect(provider.calls, hasLength(2));
    expect(sleeps, [const Duration(seconds: 5)]);
    expect(sink.texts.single, contains('rate'));
  });

  test('a huge retry-after is capped at 30 s', () async {
    provider.scripts
      ..add(
        () => Stream.error(
          const LlmException(
            'rate',
            status: 429,
            retryAfter: Duration(hours: 1),
          ),
        ),
      )
      ..add(() => answer(['ok']));
    await bridge(
      timeout: const Duration(minutes: 5),
    ).handle(conversationId: 'c', text: 'q', sink: FakeSink());
    expect(sleeps, [const Duration(seconds: 30)]);
  });

  test(
    'slow streamed answer: progress message, partial edits, final text',
    () async {
      provider.scripts.add(
        () => answer([
          'Jedna ',
          'dva ',
          'tři ',
          'čtyři.',
        ], pause: const Duration(milliseconds: 60)),
      );
      final sink = FakeSink();
      await bridge(
        progressAfter: const Duration(milliseconds: 30),
        editInterval: const Duration(milliseconds: 40),
      ).handle(conversationId: 'c', text: 'počítej', sink: sink);
      expect(sink.messages, hasLength(1));
      final msg = sink.messages.single;
      expect(msg.text, 'Jedna dva tři čtyři.');
      // At least one partial edit before the final one.
      expect(msg.edits.length, greaterThanOrEqualTo(2));
      expect(msg.edits.first, endsWith(' ...'));
      expect(msg.edits.last, 'Jedna dva tři čtyři.');
    },
  );

  test('progress edits are capped', () async {
    provider.scripts.add(
      () => answer([
        for (var i = 0; i < 30; i++) 'x$i ',
      ], pause: const Duration(milliseconds: 15)),
    );
    final sink = FakeSink();
    await bridge(
      progressAfter: const Duration(milliseconds: 1),
      editInterval: const Duration(milliseconds: 5),
      maxEdits: 2,
    ).handle(conversationId: 'c', text: 'q', sink: sink);
    final msg = sink.messages.single;
    // 2 partial edits + the final one.
    expect(msg.edits.length, 3);
    expect(msg.text, startsWith('x0 x1'));
  });

  test('a fast answer posts no progress message', () async {
    provider.scripts.add(() => answer(['hned']));
    final sink = FakeSink();
    await bridge(
      progressAfter: const Duration(seconds: 2),
    ).handle(conversationId: 'c', text: 'q', sink: sink);
    expect(sink.messages.single.edits, isEmpty);
    expect(sink.texts, ['hned']);
  });

  test('long answers are chunked', () async {
    final long = List.filled(1200, 'slovo').join(' ');
    provider.scripts.add(() => answer([long]));
    final sink = FakeSink();
    await bridge().handle(conversationId: 'c', text: 'q', sink: sink);
    expect(sink.texts.length, 2);
    expect(sink.texts.every((t) => t.length <= maxReplyChars), isTrue);
  });

  test('timeout: the subscription is cancelled and the owner told', () async {
    var cancelled = false;
    provider.scripts.add(() {
      late StreamController<String> c;
      c = StreamController<String>(onCancel: () => cancelled = true);
      return c.stream;
    });
    final sink = FakeSink();
    await bridge(
      timeout: const Duration(milliseconds: 100),
    ).handle(conversationId: 'c', text: 'q', sink: sink);
    expect(cancelled, isTrue);
    expect(sink.texts.single, contains('did not answer within'));
  });

  test('empty model answer: a note, nothing remembered', () async {
    provider.scripts.add(() => answer(['  ']));
    final sink = FakeSink();
    await bridge().handle(conversationId: 'c', text: 'q', sink: sink);
    expect(sink.texts.single, BridgeTexts.empty);
    expect(await store.history('c'), isEmpty);
  });

  test('a corrupt history file is moved aside, not fatal', () async {
    await File('${dir.path}/bad.llm').writeAsString('not encrypted');
    final s = await HistoryStore.open('${dir.path}/bad.llm', key, cap: 5);
    expect(await s.history('c'), isEmpty);
    expect(File('${dir.path}/bad.llm.corrupt').existsSync(), isTrue);
  });

  test('cap 0 remembers nothing', () async {
    store = await openStore(cap: 0);
    provider.scripts.add(() => answer(['a']));
    await bridge().handle(conversationId: 'c', text: 'q', sink: FakeSink());
    expect(await store.history('c'), isEmpty);
  });
}
