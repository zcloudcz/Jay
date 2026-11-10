import 'package:calltype/features/chat/links.dart';
import 'package:flutter_test/flutter_test.dart';

/// Visible texts of the links found in [text].
List<String> texts(String text) =>
    detectLinks(text).map((l) => l.text).toList();

/// Target Uris of the links found in [text].
List<String> uris(String text) =>
    detectLinks(text).map((l) => l.uri.toString()).toList();

void main() {
  group('web links', () {
    test('http, https and www', () {
      expect(texts('see http://a.cz and https://b.cz/x or www.c.cz'), [
        'http://a.cz',
        'https://b.cz/x',
        'www.c.cz',
      ]);
      expect(uris('www.seznam.cz'), ['https://www.seznam.cz']);
      expect(detectLinks('www.seznam.cz').single.kind, LinkKind.web);
    });

    test('scheme is case-insensitive', () {
      expect(texts('HTTPS://Example.COM/Path'), ['HTTPS://Example.COM/Path']);
      expect(texts('WWW.Example.com'), ['WWW.Example.com']);
    });

    test('offsets match the text', () {
      const text = 'Ahoj, mrkni na https://jay.zcloud.cz prosím';
      final link = detectLinks(text).single;
      expect(text.substring(link.start, link.end), link.text);
      expect(link.start, 15);
    });

    test('query, fragment and port are kept', () {
      expect(texts('go https://a.cz:8443/p?q=1&r=a%20b#frag now'), [
        'https://a.cz:8443/p?q=1&r=a%20b#frag',
      ]);
    });

    test('trailing punctuation is not part of the URL', () {
      for (final tail in ['.', ',', ';', ':', '!', '?', '...', '?!', "'"]) {
        expect(texts('see https://a.cz/x$tail'), [
          'https://a.cz/x',
        ], reason: tail);
      }
      // Inside the URL it stays.
      expect(texts('https://a.cz/a.b,c;d'), ['https://a.cz/a.b,c;d']);
    });

    test('Wikipedia style parentheses stay, outer ones go', () {
      expect(texts('(viz https://cs.wikipedia.org/wiki/Brno_(město)).'), [
        'https://cs.wikipedia.org/wiki/Brno_(město)',
      ]);
      expect(texts('(https://a.cz/x)'), ['https://a.cz/x']);
      expect(texts('[https://a.cz/x]'), ['https://a.cz/x']);
      expect(texts('{https://a.cz/x}'), ['https://a.cz/x']);
      expect(texts('https://a.cz/x_(y))))'), ['https://a.cz/x_(y)']);
    });

    test('quotes and angle brackets end the URL', () {
      expect(texts('"https://a.cz/x"'), ['https://a.cz/x']);
      expect(texts('<https://a.cz/x>'), ['https://a.cz/x']);
      expect(texts("'https://a.cz/x'"), ['https://a.cz/x']);
      expect(texts('„https://a.cz/x“'), ['https://a.cz/x']);
    });

    test('Czech text around links', () {
      const text =
          'Příliš žluťoučký kůň: https://www.idnes.cz/zpravy?id=1, '
          'a taky www.seznam.cz! Díky.';
      expect(texts(text), [
        'https://www.idnes.cz/zpravy?id=1',
        'www.seznam.cz',
      ]);
      expect(texts('Odkaz https://cs.wikipedia.org/wiki/Šumava je fajn'), [
        'https://cs.wikipedia.org/wiki/Šumava',
      ]);
    });

    test('IDN host becomes punycode, the text stays', () {
      final link = detectLinks('https://háček.cz/přehled').single;
      expect(link.text, 'https://háček.cz/přehled');
      expect(link.uri.host, 'xn--hek-ela4t.cz');
      expect(link.uri.scheme, 'https');
      expect(uris('www.münchen.de'), ['https://www.xn--mnchen-3ya.de']);
    });

    test('emoji next to a URL is not part of it', () {
      expect(texts('👉https://a.cz/x👍'), ['https://a.cz/x']);
      expect(texts('https://a.cz 🎉'), ['https://a.cz']);
    });

    test('not inside a word', () {
      expect(texts('xhttps://a.cz'), isEmpty);
      expect(texts('awww.example.com'), isEmpty);
    });

    test('incomplete candidates stay text', () {
      expect(texts('https://'), isEmpty);
      expect(texts('https:// a'), isEmpty);
      expect(texts('www. a'), isEmpty);
      expect(texts('www.'), isEmpty);
      expect(texts('www..cz'), isEmpty);
    });

    test('bare domains and other schemes are not links', () {
      expect(texts('file.txt seznam.cz v1.2'), isEmpty);
      expect(
        texts('ftp://a.cz javascript:alert(1) file:///etc tel:123 intent://x'),
        isEmpty,
      );
    });

    test('user info stays visible in the target', () {
      expect(uris('https://user@a.cz/x'), ['https://user@a.cz/x']);
    });
  });

  group('e-mail', () {
    test('plain address opens mailto', () {
      final link = detectLinks('pište na martin@zcloud.cz.').single;
      expect(link.text, 'martin@zcloud.cz');
      expect(link.uri.toString(), 'mailto:martin@zcloud.cz');
      expect(link.kind, LinkKind.email);
    });

    test('mailto link', () {
      final link = detectLinks('mailto:a@b.cz?subject=Ahoj').single;
      expect(link.uri.scheme, 'mailto');
      expect(link.text, 'mailto:a@b.cz?subject=Ahoj');
    });

    test('a mention is not an e-mail', () {
      expect(texts('@Hermes ahoj @Martin.'), isEmpty);
      expect(texts('@Hermes viz https://a.cz'), ['https://a.cz']);
    });

    test('an address needs a real top level label', () {
      expect(texts('a@b'), isEmpty);
      expect(texts('a@b.c'), isEmpty);
      expect(texts('a@b.12'), isEmpty);
      expect(texts('first.last+tag@sub.example.com'), [
        'first.last+tag@sub.example.com',
      ]);
    });

    test('an @ inside a URL belongs to the URL', () {
      expect(texts('https://mastodon.social/@user'), [
        'https://mastodon.social/@user',
      ]);
      expect(texts('https://me@a.cz'), ['https://me@a.cz']);
    });

    test('IDN domain in an address', () {
      expect(uris('jan@háček.cz'), ['mailto:jan@xn--hek-ela4t.cz']);
    });
  });

  test('several links keep their order and do not overlap', () {
    final links = detectLinks('a@b.cz https://x.cz www.y.cz mailto:c@d.cz');
    expect(links.map((l) => l.kind), [
      LinkKind.email,
      LinkKind.web,
      LinkKind.web,
      LinkKind.email,
    ]);
    for (var i = 1; i < links.length; i++) {
      expect(links[i].start, greaterThanOrEqualTo(links[i - 1].end));
    }
  });

  test('isOpenableLink allows only http, https and mailto', () {
    expect(isOpenableLink(Uri.parse('https://a.cz')), isTrue);
    expect(isOpenableLink(Uri.parse('HTTP://a.cz')), isTrue);
    expect(isOpenableLink(Uri.parse('mailto:a@b.cz')), isTrue);
    expect(isOpenableLink(Uri.parse('javascript:alert(1)')), isFalse);
    expect(isOpenableLink(Uri.parse('file:///etc/passwd')), isFalse);
    expect(isOpenableLink(Uri.parse('intent://x')), isFalse);
  });

  test('punycode matches RFC 3492', () {
    expect(punycodeEncode('münchen'), 'mnchen-3ya');
    expect(punycodeEncode('bücher'), 'bcher-kva');
    expect(punycodeEncode('příliš-žluťoučký'), 'pli-luouk-g5a8p8gr1bkdtc3x');
    expect(punycodeEncode('日本語'), 'wgv71a119e');
  });

  group('performance', () {
    test('long text with many links', () {
      final buffer = StringBuffer();
      for (var i = 0; i < 4000; i++) {
        buffer.write('Slovo číslo $i, viz https://a.cz/$i a x$i@b.cz. ');
      }
      final text = buffer.toString();
      expect(text.length, greaterThan(200000));
      final sw = Stopwatch()..start();
      final links = detectLinks(text);
      sw.stop();
      expect(links, hasLength(8000));
      expect(sw.elapsedMilliseconds, lessThan(2000));
    });

    test('pathological runs stay fast', () {
      final inputs = [
        'a' * 200000,
        '${'a.' * 100000}@',
        'https://a.cz/${')' * 100000}',
        'https://${'(' * 100000}',
        'www.${'x' * 200000}',
      ];
      for (final input in inputs) {
        final sw = Stopwatch()..start();
        detectLinks(input);
        sw.stop();
        expect(
          sw.elapsedMilliseconds,
          lessThan(2000),
          reason: input.substring(0, 20),
        );
      }
    });

    test('plain text exits early', () {
      expect(detectLinks('Ahoj, jak se máš?'), isEmpty);
    });
  });
}
