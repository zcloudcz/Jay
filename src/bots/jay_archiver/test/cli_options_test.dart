import 'package:jay_archiver/jay_archiver.dart';
import 'package:test/test.dart';

void main() {
  group('parseFlags', () {
    test('reads --key value pairs', () {
      expect(
        parseFlags(['--api', 'http://x', '--org', 'o1']),
        {'api': 'http://x', 'org': 'o1'},
      );
    });

    test('ignores a trailing flag with no value', () {
      expect(parseFlags(['--api', 'http://x', '--dangling']), {'api': 'http://x'});
    });
  });

  group('resolveOptions', () {
    test('flags alone are enough', () {
      final opts = resolveOptions(
        {'api': 'http://x', 'org': 'o1', 'state': '/data'},
        {},
      );
      expect(opts.apiBaseUrl, 'http://x');
      expect(opts.orgId, 'o1');
      expect(opts.statePath, '/data');
      expect(opts.adminToken, isNull);
    });

    test('env vars fill in for a container that passes no flags', () {
      final opts = resolveOptions({}, {
        'JAY_API_URL': 'http://x',
        'JAY_ORG_ID': 'o1',
        'JAY_STATE_DIR': '/data',
      });
      expect(opts.apiBaseUrl, 'http://x');
      expect(opts.orgId, 'o1');
      expect(opts.statePath, '/data');
    });

    test('a flag wins over the same env var', () {
      final opts = resolveOptions(
        {'api': 'http://flag'},
        {'JAY_API_URL': 'http://env', 'JAY_ORG_ID': 'o1', 'JAY_STATE_DIR': '/data'},
      );
      expect(opts.apiBaseUrl, 'http://flag');
    });

    test('missing required value throws ArgumentError naming the key', () {
      expect(
        () => resolveOptions({'api': 'http://x'}, {}),
        throwsA(isA<ArgumentError>().having((e) => e.message, 'message', contains('--org'))),
      );
    });

    test('--admin-token is optional and passed through when given', () {
      final opts = resolveOptions(
        {'api': 'http://x', 'org': 'o1', 'state': '/data', 'admin-token': 'jwt'},
        {},
      );
      expect(opts.adminToken, 'jwt');
    });
  });
}
