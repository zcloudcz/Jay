/// Pure link detection for message text (spec 2026-11-10-clickable-links).
///
/// No Flutter imports, so it is trivially unit-testable. Linear in the text
/// length (see the scanner note below).
library;

/// What a detected link opens.
enum LinkKind {
  /// `http://`, `https://` or a `www.` host (opened as https).
  web,

  /// A plain e-mail address or a `mailto:` link.
  email,
}

/// One link inside a text: `text.substring(start, end) == this.text`.
class TextLink {
  const TextLink({
    required this.start,
    required this.end,
    required this.text,
    required this.uri,
    required this.kind,
  });

  final int start;
  final int end;

  /// The visible text, exactly as written in the message.
  final String text;

  /// Where a tap goes (IDN hosts in punycode, `www.` with https).
  final Uri uri;
  final LinkKind kind;

  @override
  String toString() => 'TextLink($start-$end "$text" -> $uri)';
}

/// The only schemes that are ever opened (D2, D8). Checked again at launch.
bool isOpenableLink(Uri uri) =>
    const {'http', 'https', 'mailto'}.contains(uri.scheme.toLowerCase());

const _trailing = {'.', ',', ';', ':', '!', '?', "'"};
const _pairs = {')': '(', ']': '[', '}': '{'};

// WHY a hand-written scanner and not one big RegExp: Dart's regexp engine
// is very slow on unicode property classes (`\p{L}`) over non-Latin-1 text
// (about 25 us per character on Czech text, 4 s for 200 KB). The anchors are
// found with a plain ASCII pattern and the links are expanded around them
// character by character, so the cost is linear in the text length.
final _anchors = RegExp(
  r'[hH][tT][tT][pP][sS]?://|[wW][wW][wW]\.|[mM][aA][iI][lL][tT][oO]:|@',
);

final _tld = RegExp(r'^\p{L}{2,}$', unicode: true);
final _letterRe = RegExp(r'^[\p{L}\p{N}\p{M}]$', unicode: true);
final _letterCache = <int, bool>{};

/// A letter, digit or combining mark of any script.
bool _isAlnum(int c) {
  if (c < 0x80) {
    return (c >= 0x30 && c <= 0x39) ||
        (c >= 0x41 && c <= 0x5a) ||
        (c >= 0x61 && c <= 0x7a);
  }
  return _letterCache.putIfAbsent(
    c,
    () => _letterRe.hasMatch(String.fromCharCode(c)),
  );
}

/// Letters and digits of any script, combining marks and the URL punctuation
/// of RFC 3986. Anything else (whitespace, emoji, quotes, <, >) ends a URL.
bool _isUrlChar(int c) =>
    _isAlnum(c) || r"-._~:/?#[]@!$&'()*+,;=%".contains(String.fromCharCode(c));

bool _isLocalChar(int c) =>
    _isAlnum(c) || '._%+-'.contains(String.fromCharCode(c));

bool _isDomainChar(int c) => _isAlnum(c) || c == 0x2d || c == 0x2e;

/// Code point starting at [i] (a surrogate pair counts as one).
int _cpAt(String s, int i) {
  final c = s.codeUnitAt(i);
  if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
    final d = s.codeUnitAt(i + 1);
    if (d >= 0xdc00 && d <= 0xdfff) {
      return 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00);
    }
  }
  return c;
}

/// Code point ending just before [i], and its length in code units.
(int, int) _cpBefore(String s, int i) {
  final d = s.codeUnitAt(i - 1);
  if (d >= 0xdc00 && d <= 0xdfff && i >= 2) {
    final c = s.codeUnitAt(i - 2);
    if (c >= 0xd800 && c <= 0xdbff) {
      return (0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00), 2);
    }
  }
  return (d, 1);
}

int _expandRight(String s, int i, bool Function(int) accept) {
  while (i < s.length) {
    final c = _cpAt(s, i);
    if (!accept(c)) break;
    i += c > 0xffff ? 2 : 1;
  }
  return i;
}

int _expandLeft(String s, int i, int floor, bool Function(int) accept) {
  while (i > floor) {
    final (c, len) = _cpBefore(s, i);
    if (i - len < floor || !accept(c)) break;
    i -= len;
  }
  return i;
}

/// Finds the links in [text], in order and without overlaps.
List<TextLink> detectLinks(String text) {
  // Cheap exit for the common chat message without any link.
  if (!text.contains(':') && !text.contains('@') && !text.contains('.')) {
    return const [];
  }
  final result = <TextLink>[];
  // Everything before [pos] is already decided (a link or rejected text).
  var pos = 0;
  for (final anchor in _anchors.allMatches(text)) {
    final i = anchor.start;
    if (i < pos) continue;
    final before = i == 0 ? null : _cpBefore(text, i).$1;
    if (anchor[0] == '@') {
      final start = _expandLeft(text, i, pos, _isLocalChar);
      final end = _expandRight(text, i + 1, _isDomainChar);
      if (start == i || end == i + 1) continue;
      // Hit the end of the previous link: glued to it, not an address.
      if (start == pos &&
          start > 0 &&
          _isLocalChar(_cpBefore(text, start).$1)) {
        continue;
      }
      final candidate = _trim(text.substring(start, end));
      final uri = _emailUri(candidate);
      if (uri == null) continue;
      result.add(
        TextLink(
          start: start,
          end: start + candidate.length,
          text: candidate,
          uri: uri,
          kind: LinkKind.email,
        ),
      );
      pos = start + candidate.length;
      continue;
    }
    final lower = anchor[0]!.toLowerCase();
    final isWww = lower == 'www.';
    if (before != null &&
        (_isAlnum(before) ||
            (isWww && '.-@/'.contains(String.fromCharCode(before))))) {
      continue;
    }
    final end = _expandRight(text, i, _isUrlChar);
    // Rejected or not, this run of URL characters is decided: anchors
    // inside it are not looked at again (keeps `https://https://...` linear).
    pos = end;
    final candidate = _trim(text.substring(i, end));
    final uri = lower == 'mailto:' ? _mailtoUri(candidate) : _webUri(candidate);
    if (uri == null || !isOpenableLink(uri)) continue;
    result.add(
      TextLink(
        start: i,
        end: i + candidate.length,
        text: candidate,
        uri: uri,
        kind: lower == 'mailto:' ? LinkKind.email : LinkKind.web,
      ),
    );
    pos = i + candidate.length;
  }
  return result;
}

/// Drops trailing punctuation and unbalanced closing brackets (D3). Bracket
/// counts are computed once and updated per removed character, so a URL
/// followed by thousands of `)` stays linear.
String _trim(String s) {
  final open = <String, int>{'(': 0, '[': 0, '{': 0};
  final close = <String, int>{')': 0, ']': 0, '}': 0};
  for (var i = 0; i < s.length; i++) {
    final ch = s[i];
    if (open.containsKey(ch)) open[ch] = open[ch]! + 1;
    if (close.containsKey(ch)) close[ch] = close[ch]! + 1;
  }
  var end = s.length;
  while (end > 0) {
    final ch = s[end - 1];
    if (_trailing.contains(ch)) {
      end--;
      continue;
    }
    final opener = _pairs[ch];
    if (opener != null && close[ch]! > open[opener]!) {
      close[ch] = close[ch]! - 1;
      end--;
      continue;
    }
    break;
  }
  return s.substring(0, end);
}

Uri? _webUri(String s) {
  final lower = s.toLowerCase();
  final String scheme;
  final String rest;
  if (lower.startsWith('https://')) {
    scheme = 'https';
    rest = s.substring(8);
  } else if (lower.startsWith('http://')) {
    scheme = 'http';
    rest = s.substring(7);
  } else {
    // `www.` (D1): needs a label after it, and that label is not empty.
    scheme = 'https';
    rest = s;
    if (s.length <= 4 || '.:/?#'.contains(s[4])) return null;
  }
  final authorityEnd = _firstIndexOfAny(rest, '/?#');
  final authority = rest.substring(0, authorityEnd);
  final at = authority.lastIndexOf('@');
  final userInfo = at < 0 ? '' : authority.substring(0, at + 1);
  var hostPort = authority.substring(at + 1);
  var port = '';
  final colon = hostPort.lastIndexOf(':');
  if (colon >= 0 && !hostPort.startsWith('[')) {
    port = hostPort.substring(colon);
    hostPort = hostPort.substring(0, colon);
  }
  if (hostPort.isEmpty || hostPort.startsWith('.')) return null;
  final host = asciiHost(hostPort);
  if (host == null) return null;
  final uri = Uri.tryParse(
    '$scheme://$userInfo$host$port${rest.substring(authorityEnd)}',
  );
  if (uri == null || uri.host.isEmpty) return null;
  return uri;
}

Uri? _mailtoUri(String s) {
  final uri = Uri.tryParse(s);
  if (uri == null || !uri.path.contains('@')) return null;
  return uri;
}

Uri? _emailUri(String s) {
  final at = s.lastIndexOf('@');
  if (at <= 0) return null;
  final domain = s.substring(at + 1);
  final labels = domain.split('.');
  if (labels.length < 2 || labels.any((l) => l.isEmpty)) return null;
  if (!_tld.hasMatch(labels.last)) return null;
  final host = asciiHost(domain);
  if (host == null) return null;
  return Uri.tryParse('mailto:${s.substring(0, at)}@$host');
}

int _firstIndexOfAny(String s, String chars) {
  for (var i = 0; i < s.length; i++) {
    if (chars.contains(s[i])) return i;
  }
  return s.length;
}

/// [host] with every non-ASCII label converted to punycode (`xn--`, RFC
/// 3492), lower case; null for an empty label in the middle.
String? asciiHost(String host) {
  final labels = host.split('.');
  final out = <String>[];
  for (var i = 0; i < labels.length; i++) {
    final label = labels[i];
    if (label.isEmpty) {
      // A trailing dot (FQDN) is fine, an empty inner label is not.
      if (i == labels.length - 1 && i > 0) {
        out.add(label);
        continue;
      }
      return null;
    }
    if (label.runes.every((c) => c < 0x80)) {
      out.add(label);
    } else {
      out.add('xn--${punycodeEncode(label.toLowerCase())}');
    }
  }
  return out.join('.');
}

const _base = 36;
const _tMin = 1;
const _tMax = 26;
const _skew = 38;
const _damp = 700;

/// RFC 3492 punycode encoding of one label (without the `xn--` prefix).
String punycodeEncode(String input) {
  final cps = input.runes.toList();
  final out = StringBuffer();
  for (final c in cps) {
    if (c < 0x80) out.writeCharCode(c);
  }
  final basic = out.length;
  var handled = basic;
  if (basic > 0) out.write('-');
  var n = 0x80;
  var delta = 0;
  var bias = 72;
  while (handled < cps.length) {
    var m = 0x10FFFF + 1;
    for (final c in cps) {
      if (c >= n && c < m) m = c;
    }
    delta += (m - n) * (handled + 1);
    n = m;
    for (final c in cps) {
      if (c < n) delta++;
      if (c == n) {
        var q = delta;
        for (var k = _base; ; k += _base) {
          final t = k <= bias
              ? _tMin
              : k >= bias + _tMax
              ? _tMax
              : k - bias;
          if (q < t) break;
          out.writeCharCode(_digit(t + (q - t) % (_base - t)));
          q = (q - t) ~/ (_base - t);
        }
        out.writeCharCode(_digit(q));
        bias = _adapt(delta, handled + 1, handled == basic);
        delta = 0;
        handled++;
      }
    }
    delta++;
    n++;
  }
  return out.toString();
}

int _digit(int d) => d < 26 ? 0x61 + d : 0x30 + d - 26;

int _adapt(int delta, int numPoints, bool first) {
  var d = first ? delta ~/ _damp : delta ~/ 2;
  d += d ~/ numPoints;
  var k = 0;
  while (d > ((_base - _tMin) * _tMax) ~/ 2) {
    d ~/= _base - _tMin;
    k += _base;
  }
  return k + (_base - _tMin + 1) * d ~/ (d + _skew);
}
