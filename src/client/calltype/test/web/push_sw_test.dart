import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Runs the Node unit test of web/push-sw.js (push display and the click
/// routing) as part of `flutter test`, so the worker cannot rot unnoticed.
/// Skipped where no `node` is installed; the worker itself is plain JS with no
/// build step.
void main() {
  final node = _which('node');

  test('push service worker exists and is served from the web root', () {
    final worker = File('web/push-sw.js');
    expect(worker.existsSync(), isTrue);
    final source = worker.readAsStringSync();
    expect(source, contains("addEventListener('push'"));
    expect(source, contains("addEventListener('notificationclick'"));
    // No fetch handler: the worker must never intercept app or /admin/ requests.
    expect(source, isNot(contains("addEventListener('fetch'")));
  });

  test(
    'push-sw.js behaves (node --test test/web/push_sw.test.mjs)',
    () async {
      final result = await Process.run(node!, [
        '--test',
        'test/web/push_sw.test.mjs',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    skip: node == null ? 'node is not installed' : false,
  );
}

String? _which(String command) {
  try {
    final result = Process.runSync(Platform.isWindows ? 'where' : 'which', [
      command,
    ]);
    if (result.exitCode != 0) return null;
    final path = (result.stdout as String).trim().split('\n').first.trim();
    return path.isEmpty ? null : path;
  } on ProcessException {
    return null;
  }
}
