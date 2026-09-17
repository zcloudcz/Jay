import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Cheap regression guard: UI text must come from lib/l10n (`context.l10n`),
/// not from string literals. Deliberately a dumb text scan, not an analyzer
/// plugin — it catches the common slip (`Text('Save')`, `tooltip: 'Send'`)
/// and costs nothing to run.
// ponytail: regex scan, misses literals passed through variables or helper
// parameters; switch to a custom lint if that ever becomes a real problem.
void main() {
  /// Literals that are intentionally not translated.
  const allowed = {
    'BOT', // fixed badge label
    'Jay', // product name
  };

  // `Text('…'` (also `const Text(` / `SelectableText(`, literal on the next
  // line) and the named parameters that end up on screen.
  final patterns = [
    RegExp(r'''Text\(\s*(?:const\s+)?(['"])((?:(?!\1).)*)\1'''),
    RegExp(
      r'''\b(?:labelText|hintText|helperText|errorText|tooltip|label|semanticLabel|semanticsLabel)\s*:\s*(['"])((?:(?!\1).)*)\1''',
    ),
  ];

  /// Letters left after removing `$var` / `${expr}` interpolations — a
  /// literal such as `'$count'` or `'${a} · ${b}'` carries no language.
  bool hasWords(String literal) => RegExp(r'\p{L}', unicode: true).hasMatch(
    literal
        .replaceAll(RegExp(r'\$\{[^}]*\}'), '')
        .replaceAll(RegExp(r'\$\w+'), ''),
  );

  test('lib/features and lib/shared contain no hard-coded UI strings', () {
    final offenders = <String>[];
    for (final root in ['lib/features', 'lib/shared', 'lib/app']) {
      final files = Directory(root)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart') && !f.path.endsWith('.g.dart'));
      for (final file in files) {
        final source = file.readAsStringSync();
        for (final pattern in patterns) {
          for (final match in pattern.allMatches(source)) {
            final literal = match.group(2)!;
            if (!hasWords(literal) || allowed.contains(literal)) continue;
            final line = '\n'.allMatches(source.substring(0, match.start)).length + 1;
            offenders.add('${file.path}:$line  "$literal"');
          }
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'Move these strings to lib/l10n/app_en.arb (+ translations) and '
          'read them via context.l10n:\n${offenders.join('\n')}',
    );
  });
}
