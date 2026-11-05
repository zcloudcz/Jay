import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Both ARBs must carry the same keys and placeholders: gen-l10n silently
/// falls back to English for a missing cs key, which an operator would only
/// notice in the middle of a decision.
void main() {
  Map<String, dynamic> load(String lang) =>
      jsonDecode(File('lib/l10n/app_$lang.arb').readAsStringSync()) as Map<String, dynamic>;

  test('cs and en have the same message keys', () {
    final en = load('en').keys.where((k) => !k.startsWith('@')).toSet();
    final cs = load('cs').keys.where((k) => !k.startsWith('@')).toSet();
    expect(cs.difference(en), isEmpty);
    expect(en.difference(cs), isEmpty);
  });

  test('placeholders match', () {
    final en = load('en');
    final cs = load('cs');
    final re = RegExp(r'\{(\w+)[,}]');
    for (final k in en.keys.where((k) => !k.startsWith('@'))) {
      final a = re.allMatches(en[k] as String).map((m) => m[1]).toSet();
      final b = re.allMatches(cs[k] as String).map((m) => m[1]).toSet();
      expect(b, a, reason: k);
    }
  });

  test('every rule K1..K10 has a title in both languages', () {
    for (final lang in ['en', 'cs']) {
      final m = load(lang);
      for (var i = 1; i <= 10; i++) {
        expect((m['ruleK$i'] as String?)?.isNotEmpty, isTrue, reason: '$lang K$i');
      }
    }
  });
}
