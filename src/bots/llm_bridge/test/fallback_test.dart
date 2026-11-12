import 'dart:async';

import 'package:llm_bridge/llm_bridge.dart';
import 'package:test/test.dart';

/// A provider whose every call runs [script]; records calls and cancels.
class _Fake implements LlmProvider {
  _Fake(this.label, this.script);

  @override
  final String label;
  final Stream<String> Function() script;
  var calls = 0;
  var cancels = 0;

  @override
  Stream<String> reply(List<ChatTurn> conversation, {required String system}) {
    calls++;
    late final StreamController<String> c;
    StreamSubscription<String>? sub;
    c = StreamController<String>(
      onListen: () {
        sub = script().listen(c.add, onError: c.addError, onDone: c.close);
      },
      onCancel: () {
        cancels++;
        return sub?.cancel();
      },
    );
    return c.stream;
  }

  @override
  Future<void> close() async {}
}

Stream<String> _fail(String message, {int? status}) =>
    Stream.error(LlmException(message, status: status));

Stream<String> _pieces(List<String> pieces) => Stream.fromIterable(pieces);

/// Never emits, never ends (a hung CLI).
Stream<String> _hang() => StreamController<String>().stream;

void main() {
  const conv = [ChatTurn.user('ahoj')];
  final logs = <String>[];
  setUp(logs.clear);

  test(
    'error before text switches to the next provider (F4, F7 log)',
    () async {
      final a = _Fake('Claude Code CLI', () => _fail('not logged in'));
      final b = _Fake('Codex CLI', () => _pieces(['Ahoj', '!']));
      final chain = FallbackProvider([a, b], log: logs.add);
      expect(await chain.reply(conv, system: 's').join(), 'Ahoj!');
      expect([a.calls, b.calls], [1, 1]);
      expect(logs, [
        'LLM: Claude Code CLI failed (not logged in), trying Codex CLI.',
      ]);
    },
  );

  test('a 429 switches at once too (F10)', () async {
    final a = _Fake('A', () => _fail('rate', status: 429));
    final b = _Fake('B', () => _pieces(['ok']));
    expect(
      await FallbackProvider([a, b]).reply(conv, system: 's').join(),
      'ok',
    );
  });

  test('a non-LlmException error (launch failure) also switches', () async {
    final a = _Fake('A', () => Stream.error(StateError('boom')));
    final b = _Fake('B', () => _pieces(['ok']));
    expect(
      await FallbackProvider([a, b]).reply(conv, system: 's').join(),
      'ok',
    );
  });

  test('error after text does not switch', () async {
    Stream<String> partly() async* {
      yield 'Ahoj';
      throw const LlmException('connection reset');
    }

    final a = _Fake('A', partly);
    final b = _Fake('B', () => _pieces(['never']));
    final got = <String>[];
    await expectLater(
      FallbackProvider([a, b]).reply(conv, system: 's').forEach(got.add),
      throwsA(
        isA<LlmException>().having((e) => e.message, 'm', 'connection reset'),
      ),
    );
    expect(got, ['Ahoj']);
    expect(b.calls, 0);
  });

  test('an empty piece is not text: the switch still happens', () async {
    Stream<String> emptyThenFail() async* {
      yield '';
      throw const LlmException('x');
    }

    final a = _Fake('A', emptyThenFail);
    final b = _Fake('B', () => _pieces(['ok']));
    expect(
      await FallbackProvider([a, b]).reply(conv, system: 's').join(),
      'ok',
    );
  });

  test('all fail: every label named, last status kept (F5)', () async {
    final a = _Fake('Claude Code CLI', () => _fail('quota', status: 429));
    final b = _Fake('Codex CLI', () => _fail('bad key', status: 401));
    await expectLater(
      FallbackProvider([a, b]).reply(conv, system: 's').join(),
      throwsA(
        isA<LlmException>()
            .having(
              (e) => e.message,
              'm',
              'Claude Code CLI: quota; Codex CLI: bad key',
            )
            .having((e) => e.status, 'status', 401)
            .having((e) => e.isAuth, 'isAuth', isTrue),
      ),
    );
  });

  test('cancel stops the running attempt and starts no other (F6)', () async {
    final a = _Fake('A', _hang);
    final b = _Fake('B', () => _pieces(['never']));
    final sub = FallbackProvider([
      a,
      b,
    ]).reply(conv, system: 's').listen((_) {});
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(a.cancels, 1);
    expect(b.calls, 0);
  });

  group('FirstOutputGuard (F11)', () {
    test('a hung attempt is cancelled and fails, the next one runs', () async {
      final a = _Fake('Claude Code CLI', _hang);
      final b = _Fake('Codex CLI', () => _pieces(['ok']));
      final chain = FallbackProvider([
        FirstOutputGuard(a, const Duration(milliseconds: 30)),
        FirstOutputGuard(b, const Duration(milliseconds: 30)),
      ], log: logs.add);
      expect(await chain.reply(conv, system: 's').join(), 'ok');
      expect(a.cancels, 1);
      expect(logs.single, contains('Claude Code CLI sent no answer within'));
    });

    test('no fallback: the guard alone fails the hung provider', () async {
      final a = _Fake('A', _hang);
      await expectLater(
        FirstOutputGuard(
          a,
          const Duration(milliseconds: 20),
        ).reply(conv, system: 's').join(),
        throwsA(
          isA<LlmException>().having(
            (e) => e.message,
            'm',
            'A sent no answer within 0 s',
          ),
        ),
      );
      expect(a.cancels, 1);
    });

    test('text in time: no timeout later, even for a slow rest', () async {
      Stream<String> slow() async* {
        yield 'a';
        await Future<void>.delayed(const Duration(milliseconds: 60));
        yield 'b';
      }

      final g = FirstOutputGuard(
        _Fake('A', slow),
        const Duration(milliseconds: 20),
      );
      expect(await g.reply(conv, system: 's').join(), 'ab');
    });
  });
}
