import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The "New bot" commands download https://jay.zcloud.cz/bots/new-bot.sh and
/// .ps1 (spec 2026-11-09-bot-factory, B6). They are served by the app's
/// Static Web App from web/bots/, which links to infra/bots/ (one source).
/// Without the navigationFallback exclusion the host would answer with the
/// Flutter index.html and `bash` would run HTML.
void main() {
  final config =
      jsonDecode(File('web/staticwebapp.config.json').readAsStringSync())
          as Map<String, dynamic>;

  test('/bots/* is excluded from the SPA fallback', () {
    final exclude = (config['navigationFallback'] as Map)['exclude'] as List;
    expect(exclude, contains('/bots/*'));
  });

  test('scripts are served as UTF-8 text', () {
    final mime = config['mimeTypes'] as Map;
    expect(mime['.sh'], 'text/plain; charset=utf-8');
    expect(mime['.ps1'], 'text/plain; charset=utf-8');
  });

  test('web/bots serves exactly the infra/bots scripts', () {
    for (final (served, source) in [
      ('web/bots/new-bot.sh', '../../../infra/bots/jay-new-bot.sh'),
      ('web/bots/new-bot.ps1', '../../../infra/bots/jay-new-bot.ps1'),
    ]) {
      final file = File(served);
      expect(file.existsSync(), isTrue, reason: served);
      expect(
        file.readAsStringSync(),
        File(source).readAsStringSync(),
        reason: '$served must be the same file as $source',
      );
    }
    expect(File('web/bots/new-bot.sh').readAsStringSync(), startsWith('#!'));
  });

  test('scripts are ASCII (PowerShell 5.1 reads BOM-less files as ANSI)', () {
    for (final path in ['web/bots/new-bot.sh', 'web/bots/new-bot.ps1']) {
      final bytes = File(path).readAsBytesSync();
      expect(bytes.every((b) => b < 128), isTrue, reason: path);
    }
  });
}
