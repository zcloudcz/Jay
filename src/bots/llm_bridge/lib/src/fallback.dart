import 'dart:async';

import 'provider.dart';

/// Gives [inner] [limit] to emit its first text piece (spec F11): on expiry
/// the attempt is cancelled (an HTTP request aborted, a CLI process killed)
/// and fails with an [LlmException], so a fallback can run.
///
/// Note for CLI providers: they emit the whole answer at once when the
/// process ends, so for them [limit] bounds the whole run.
class FirstOutputGuard implements LlmProvider {
  FirstOutputGuard(this.inner, this.limit);

  final LlmProvider inner;
  final Duration limit;

  @override
  String get label => inner.label;

  @override
  Stream<String> reply(List<ChatTurn> conversation, {required String system}) {
    late final StreamController<String> controller;
    StreamSubscription<String>? sub;
    Timer? timer;
    controller = StreamController<String>(
      onListen: () {
        sub = inner
            .reply(conversation, system: system)
            .listen(
              (piece) {
                if (controller.isClosed) return;
                if (piece.isNotEmpty) timer?.cancel();
                controller.add(piece);
              },
              onError: (Object e, StackTrace st) {
                timer?.cancel();
                if (controller.isClosed) return;
                controller.addError(e, st);
                unawaited(controller.close());
              },
              onDone: () {
                timer?.cancel();
                if (!controller.isClosed) unawaited(controller.close());
              },
              cancelOnError: true,
            );
        timer = Timer(limit, () {
          if (controller.isClosed) return;
          unawaited(sub?.cancel());
          controller.addError(
            LlmException(
              '${inner.label} sent no answer within ${limit.inSeconds} s',
            ),
          );
          unawaited(controller.close());
        });
      },
      onCancel: () {
        timer?.cancel();
        return sub?.cancel();
      },
    );
    return controller.stream;
  }

  @override
  Future<void> close() => inner.close();
}

/// Tries [providers] in order (spec 2026-11-12-llm-bridge-fallback-rescue
/// F4-F7): the next one runs when the current one fails BEFORE it emitted
/// any text. After the first piece there is no switch (two answers would be
/// glued together); a later error goes to the caller as it is.
class FallbackProvider implements LlmProvider {
  FallbackProvider(this.providers, {this.log = _noLog})
    : assert(providers.length > 1);

  static void _noLog(String _) {}

  final List<LlmProvider> providers;
  final void Function(String) log;

  /// `Claude Code CLI -> Codex CLI` (F7).
  @override
  String get label => providers.map((p) => p.label).join(' -> ');

  @override
  Stream<String> reply(List<ChatTurn> conversation, {required String system}) {
    late final StreamController<String> controller;
    StreamSubscription<String>? current;
    var cancelled = false;
    final failures = <String>[];

    void attempt(int i) {
      if (cancelled) return;
      final provider = providers[i];
      var emitted = false;
      current = provider
          .reply(conversation, system: system)
          .listen(
            (piece) {
              if (piece.isNotEmpty) emitted = true;
              controller.add(piece);
            },
            onError: (Object error, StackTrace st) {
              if (cancelled) return;
              final e = error is LlmException ? error : LlmException('$error');
              if (emitted) {
                controller.addError(e, st);
                unawaited(controller.close());
                return;
              }
              failures.add('${provider.label}: ${e.message}');
              if (i + 1 < providers.length) {
                log(
                  'LLM: ${provider.label} failed (${_short(e.message)}), '
                  'trying ${providers[i + 1].label}.',
                );
                attempt(i + 1);
                return;
              }
              // F5: every failure named; status and retry-after of the
              // LAST provider (bridge.dart's isAuth check sees that one).
              controller.addError(
                LlmException(
                  failures.join('; '),
                  status: e.status,
                  retryAfter: e.retryAfter,
                ),
                st,
              );
              unawaited(controller.close());
            },
            onDone: () => unawaited(controller.close()),
            cancelOnError: true,
          );
    }

    controller = StreamController<String>(
      onListen: () => attempt(0),
      // F6: the attempt in flight is cancelled, no further one starts.
      onCancel: () {
        cancelled = true;
        return current?.cancel();
      },
    );
    return controller.stream;
  }

  static String _short(String text) {
    final t = text.trim().replaceAll('\n', ' ');
    return t.length <= 200 ? t : '${t.substring(0, 197)}...';
  }

  @override
  Future<void> close() async {
    for (final p in providers) {
      await p.close();
    }
  }
}
