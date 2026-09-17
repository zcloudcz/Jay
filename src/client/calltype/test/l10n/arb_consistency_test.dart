import 'dart:convert';
import 'dart:io';

import 'package:calltype/l10n/l10n.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guards the translation files themselves. gen_l10n only WARNS about a
/// missing key (and silently falls back to English), so without this test a
/// half-translated language would ship unnoticed.
void main() {
  const languages = [
    'en', 'cs', 'sk', 'de', 'fr', 'es', 'it', 'pt', 'pl', 'nl', //
    'uk', 'ro', 'hu', 'zh', 'hi', 'ar', 'ru', 'ja', 'tr',
  ];

  /// Plural categories a translation MUST provide so every number reads
  /// naturally. Languages not listed only need `other`.
  const requiredPluralCategories = <String, Set<String>>{
    'cs': {'one', 'few', 'many', 'other'},
    'sk': {'one', 'few', 'many', 'other'},
    'pl': {'one', 'few', 'many', 'other'},
    'uk': {'one', 'few', 'many', 'other'},
    'ru': {'one', 'few', 'many', 'other'},
    'ro': {'one', 'few', 'other'},
    'ar': {'zero', 'one', 'two', 'few', 'many', 'other'},
  };

  Map<String, dynamic> load(String language) =>
      jsonDecode(File('lib/l10n/app_$language.arb').readAsStringSync())
          as Map<String, dynamic>;

  Set<String> messageKeys(Map<String, dynamic> arb) => {
    for (final key in arb.keys)
      if (!key.startsWith('@')) key,
  };

  /// Placeholder names of a message: `{name}` and the `{count, plural, …}`
  /// variable. Plural branch bodies are scanned too, since `{count}` is
  /// repeated inside them.
  Set<String> placeholders(String message) => {
    for (final m in RegExp(r'\{\s*([A-Za-z_]\w*)\s*[,}]').allMatches(message))
      m.group(1)!,
  };

  /// Branch selectors of the (single, top-level) plural in [message].
  Set<String> pluralCategories(String message) => {
    for (final m in RegExp(r'(=\d+|zero|one|two|few|many|other)\s*\{')
        .allMatches(message.substring(message.indexOf('plural,'))))
      m.group(1)!,
  };

  final template = load('en');
  final templateKeys = messageKeys(template);

  test('exactly the 19 agreed languages ship, English first (= fallback)', () {
    final files = Directory('lib/l10n')
        .listSync()
        .map((f) => f.uri.pathSegments.last)
        .where((name) => name.endsWith('.arb'))
        .toSet();
    expect(files, {for (final l in languages) 'app_$l.arb'});
    expect(
      AppLocalizations.supportedLocales.map((l) => l.languageCode).toSet(),
      languages.toSet(),
    );
    // Flutter falls back to the FIRST supported locale for an unknown one.
    expect(AppLocalizations.supportedLocales.first, const Locale('en'));
  });

  for (final language in languages.skip(1)) {
    group('app_$language.arb', () {
      final arb = load(language);

      test('declares its locale and has the template key set', () {
        expect(arb['@@locale'], language);
        final keys = messageKeys(arb);
        expect(templateKeys.difference(keys), isEmpty, reason: 'missing keys');
        expect(keys.difference(templateKeys), isEmpty, reason: 'unknown keys');
      });

      test('no empty values, identical placeholders, balanced braces', () {
        for (final key in templateKeys) {
          final value = arb[key];
          expect(value, isA<String>(), reason: key);
          final text = value as String;
          expect(text.trim(), isNotEmpty, reason: '$key is empty');
          expect(
            placeholders(text),
            placeholders(template[key] as String),
            reason: '$key placeholders differ from the template',
          );
          expect(
            '{'.allMatches(text).length,
            '}'.allMatches(text).length,
            reason: '$key has unbalanced braces',
          );
        }
      });

      test('plural messages carry the categories the language needs', () {
        final pluralKeys = templateKeys.where(
          (k) => (template[k] as String).contains('plural,'),
        );
        expect(pluralKeys, isNotEmpty);
        for (final key in pluralKeys) {
          final text = arb[key] as String;
          expect(text, contains('plural,'), reason: '$key lost its plural');
          final categories = pluralCategories(text);
          // `=0` is an accepted spelling of Arabic's `zero`.
          if (categories.contains('=0')) categories.add('zero');
          expect(
            categories,
            containsAll(requiredPluralCategories[language] ?? {'other'}),
            reason: '$key misses plural categories for $language',
          );
        }
      });
    });
  }

  test('plural messages format for every language and typical counts', () {
    // Exercises the GENERATED code, i.e. proves the ICU syntax really parsed
    // and no branch leaks raw `{count}` / ICU syntax to the user.
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      for (final count in [0, 1, 2, 3, 5, 11, 21, 100, 1000]) {
        for (final text in [
          l10n.channelFollowers(count),
          l10n.groupSelectedCount(count),
          l10n.sizeBytes(count),
        ]) {
          expect(text.trim(), isNotEmpty, reason: '$locale / $count');
          expect(text, isNot(contains('{')), reason: '$locale / $count');
          expect(text, isNot(contains('plural')), reason: '$locale / $count');
        }
      }
    }
  });

  test('placeholders are substituted in every language', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      expect(l10n.contactsAdded('CT-AB12-CD34'), contains('CT-AB12-CD34'));
      expect(l10n.channelDeleteConfirmTitle('News'), contains('News'));
      expect(l10n.backupErrorLimitReached(3), contains('3'));
      expect(l10n.settingsVersion('1.0.0'), contains('Jay'));
      // The product name and the badge label are never translated.
      expect(l10n.botNotice, contains('Jay'));
      expect(l10n.botNotice, contains('BOT'));
    }
  });
}
