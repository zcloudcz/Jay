import 'dart:io';

import 'package:test/test.dart';

/// The dependency rule of calltype_protocol, checked on every `dart test`
/// (and in CI): the protocol is the audit boundary, so it must not reach a
/// network, a database, Flutter or the client package. It must also stay
/// usable on the web (the app's web build compiles it), hence no dart:io in
/// lib/.
///
/// Scans pubspec.yaml (dependencies, dev_dependencies,
/// dependency_overrides) and every import/export/part directive under lib/.
void main() {
  const forbiddenPackages = ['dio', 'drift', 'signalr', 'flutter', 'sqlite3'];
  const allowedDependencies = {'crypto', 'cryptography'};
  // lib/testing/ is test support (vector runner) and may read files.
  const forbiddenLibraries = ['dart:ui', 'dart:html', 'dart:ffi'];

  bool forbidden(String name) =>
      name == 'calltype_core' ||
      forbiddenPackages.any((p) => name == p || name.startsWith('${p}_'));

  Map<String, List<String>> pubspecSections() {
    final sections = <String, List<String>>{};
    String? current;
    for (final line in File('pubspec.yaml').readAsLinesSync()) {
      final top = RegExp(r'^([a-z_]+):').firstMatch(line);
      if (top != null) {
        current = top.group(1);
        continue;
      }
      final entry = RegExp(r'^  ([a-zA-Z0-9_]+):').firstMatch(line);
      if (entry != null && current != null) {
        sections.putIfAbsent(current, () => []).add(entry.group(1)!);
      }
    }
    return sections;
  }

  test('pubspec has only crypto dependencies', () {
    final sections = pubspecSections();
    final deps = sections['dependencies'] ?? [];
    expect(
      deps.toSet().difference(allowedDependencies),
      isEmpty,
      reason: 'dependencies may only be $allowedDependencies',
    );
    for (final section in [
      'dependencies',
      'dev_dependencies',
      'dependency_overrides',
    ]) {
      final bad = (sections[section] ?? []).where(forbidden).toList();
      expect(bad, isEmpty, reason: '$section must not contain $bad');
    }
    // A `sdk: flutter` entry would make the package a Flutter package.
    expect(
      File('pubspec.yaml').readAsStringSync(),
      isNot(contains('sdk: flutter')),
    );
  });

  test('lib/ imports no network, database, Flutter or client code', () {
    final directive = RegExp(
      r'''^\s*(?:import|export|part)\s+['"]([^'"]+)['"]''',
      multiLine: true,
    );
    final violations = <String>[];
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();
    expect(files, isNotEmpty);
    for (final file in files) {
      final testing = file.path.contains(
        '${Platform.pathSeparator}testing${Platform.pathSeparator}',
      );
      for (final m in directive.allMatches(file.readAsStringSync())) {
        final uri = m.group(1)!;
        final package = uri.startsWith('package:')
            ? uri.substring(8).split('/').first
            : null;
        if (package != null && forbidden(package)) {
          violations.add('${file.path}: $uri');
        }
        if (forbiddenLibraries.contains(uri) ||
            (!testing && uri == 'dart:io')) {
          violations.add('${file.path}: $uri');
        }
      }
    }
    expect(violations, isEmpty);
  });
}
