import 'dart:convert';
import 'dart:io';

import 'package:calltype/features/privacy/legal_links.dart';
import 'package:flutter_test/flutter_test.dart';

/// Legal and support pages (spec 2026-11-14-go-live W1-W6). They are static
/// files of the app's Static Web App, linked from the app, the stores (Data
/// safety, App Privacy, Support URL) and from each other. Without the
/// navigationFallback exclusion the host answers them with the Flutter
/// index.html, which a store reviewer would read as a missing policy.
void main() {
  final config =
      jsonDecode(File('web/staticwebapp.config.json').readAsStringSync())
          as Map<String, dynamic>;
  final exclude = (config['navigationFallback'] as Map)['exclude'] as List;

  test('/legal/* and /.well-known/* are excluded from the SPA fallback', () {
    expect(exclude, containsAll(['/legal/*', '/.well-known/*']));
  });

  test('security.txt is a real file served as text', () {
    final file = File('web/.well-known/security.txt');
    expect(file.existsSync(), isTrue);
    final text = file.readAsStringSync();
    expect(text, contains('Contact: mailto:'));
    final expires = RegExp(r'Expires: (\S+)').firstMatch(text)!.group(1)!;
    expect(
      DateTime.parse(expires).isAfter(DateTime.now()),
      isTrue,
      reason: 'RFC 9116: an expired security.txt must not be trusted',
    );
    final route = (config['routes'] as List).cast<Map>().firstWhere(
      (r) => r['route'] == '/.well-known/security.txt',
    );
    expect((route['headers'] as Map)['Content-Type'], startsWith('text/plain'));
  });

  for (final page in LegalPage.values) {
    for (final lang in ['cs', 'en']) {
      final name = '${page.slug}-$lang.html';
      test('$name exists, links its twin and has the operator footer', () {
        final file = File('web/legal/$name');
        expect(file.existsSync(), isTrue, reason: 'linked from the app');
        final html = file.readAsStringSync();
        final twin = '${page.slug}-${lang == 'cs' ? 'en' : 'cs'}.html';
        expect(html, contains('href="$twin"'));
        expect(html, contains('<html lang="$lang">'));
        expect(html, contains('<footer id="operator">'));
        for (final fact in [
          '07783809',
          'Havlíčkova 1550/54',
          'info@zcloud.cz',
        ]) {
          expect(html, contains(fact));
        }
        expect(html, isNot(contains('\u2014')), reason: 'no em dashes');
        // Every relative link points to an existing page.
        for (final m in RegExp(r'href="([a-z-]+\.html)"').allMatches(html)) {
          expect(
            File('web/legal/${m.group(1)}').existsSync(),
            isTrue,
            reason: '$name links ${m.group(1)}',
          );
        }
      });
    }
  }

  test('app links resolve to the files above', () {
    for (final page in LegalPage.values) {
      for (final lang in ['cs', 'en', 'de']) {
        final url = legalUrl(page, lang);
        expect(url, startsWith('https://jay.zcloud.cz/legal/'));
        expect(
          File('web/legal/${Uri.parse(url).pathSegments.last}').existsSync(),
          isTrue,
          reason: url,
        );
      }
    }
  });
}
