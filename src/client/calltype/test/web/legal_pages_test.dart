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

  // The bot guide (web/help/): linked from the support pages, so it must be
  // served as itself (not the Flutter index.html) and its images too.
  test('/help/* is excluded from the SPA fallback', () {
    expect(exclude, contains('/help/*'));
  });

  for (final lang in ['cs', 'en']) {
    final name = 'bots-$lang.html';
    test('help/$name exists, links its twin and the support page', () {
      final file = File('web/help/$name');
      expect(file.existsSync(), isTrue, reason: 'linked from support-$lang');
      final html = file.readAsStringSync();
      expect(html, contains('<html lang="$lang">'));
      expect(html, contains('href="bots-${lang == 'cs' ? 'en' : 'cs'}.html"'));
      expect(html, contains('<footer id="operator">'));
      expect(
        File('web/legal/support-$lang.html').readAsStringSync(),
        contains('href="../help/$name"'),
      );
      // Every screenshot has an alt text.
      for (final m in RegExp(r'<img [^>]*>').allMatches(html)) {
        expect(m.group(0), matches(RegExp(r'alt="[^"]{10,}"')));
      }
    });
  }

  // Relative links, images and #anchors of every static page resolve, so a
  // renamed heading or a missing screenshot fails here and not for a reader.
  test('static pages have no broken internal links or anchors', () {
    final pages = [
      ...Directory('web/legal').listSync(),
      ...Directory('web/help').listSync(),
    ].whereType<File>().where((f) => f.path.endsWith('.html'));
    final ids = <String, Set<String>>{};
    Set<String> idsOf(File f) => ids.putIfAbsent(
      f.absolute.path,
      () => RegExp(
        r'id="([^"]+)"',
      ).allMatches(f.readAsStringSync()).map((m) => m.group(1)!).toSet(),
    );
    for (final page in pages) {
      final html = page.readAsStringSync();
      expect(html, isNot(contains('\u2014')), reason: '${page.path}: em dash');
      final refs = RegExp(
        r'(?:href|src)="([^"]+)"',
      ).allMatches(html).map((m) => m.group(1)!);
      for (final ref in refs) {
        if (ref.contains(':')) continue; // https:, mailto:
        final parts = ref.split('#');
        final target = parts[0].isEmpty
            ? page
            : File('${page.parent.path}/${parts[0]}');
        expect(target.existsSync(), isTrue, reason: '${page.path} -> $ref');
        if (parts.length > 1) {
          expect(
            idsOf(target),
            contains(parts[1]),
            reason: '${page.path} -> $ref',
          );
        }
      }
    }
  });

  test('bot guide images stay small', () {
    final total = Directory('web/help')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => !f.path.endsWith('.html'))
        .fold<int>(0, (sum, f) => sum + f.lengthSync());
    expect(total, lessThan(2 * 1024 * 1024));
  });
}
