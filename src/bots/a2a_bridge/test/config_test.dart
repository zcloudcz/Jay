import 'package:a2a_bridge/a2a_bridge.dart';
import 'package:test/test.dart';

void main() {
  final base = {
    'CALLTYPE_API_URL': 'https://api.example',
    'A2A_AGENT_URL': 'http://127.0.0.1:9900',
    'ALLOWED_HANDLES': 'ct-abcd-efgh, CT-1234-5678',
  };

  test('defaults', () {
    final c = BridgeConfig.fromEnvironment(base);
    expect(c.allowedHandles, {'CT-ABCD-EFGH', 'CT-1234-5678'});
    expect(c.storePath, '/data/bot.store');
    expect(c.statePath, '/data/bot.store.a2a.json');
    expect(c.timeout, const Duration(seconds: 300));
    expect(c.pollInterval, const Duration(seconds: 3));
    expect(c.token, isNull);
    expect(c.displayName, isNull);
  });

  test('ACK_REACTIONS: on by default, off, typo refused', () {
    expect(BridgeConfig.fromEnvironment(base).ackReactions, isTrue);
    expect(
      BridgeConfig.fromEnvironment({
        ...base,
        'ACK_REACTIONS': 'off',
      }).ackReactions,
      isFalse,
    );
    expect(
      () => BridgeConfig.fromEnvironment({...base, 'ACK_REACTIONS': 'maybe'}),
      throwsA(isA<ConfigException>()),
    );
  });

  test('overrides', () {
    final c = BridgeConfig.fromEnvironment({
      ...base,
      'BOT_STORE_PATH': '/x/b.store',
      'A2A_TOKEN': 't',
      'BOT_DISPLAY_NAME': 'Copilot',
      'A2A_TIMEOUT_SECONDS': '60',
      'A2A_POLL_SECONDS': '1',
    });
    expect(c.statePath, '/x/b.store.a2a.json');
    expect(c.token, 't');
    expect(c.displayName, 'Copilot');
    expect(c.timeout, const Duration(seconds: 60));
    expect(c.pollInterval, const Duration(seconds: 1));
  });

  test('ALLOWED_HANDLES empty or missing refuses to start', () {
    for (final raw in [null, '', ' , ']) {
      final env = {...base}..remove('ALLOWED_HANDLES');
      if (raw != null) env['ALLOWED_HANDLES'] = raw;
      expect(
        () => BridgeConfig.fromEnvironment(env),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('refusing to start'),
          ),
        ),
      );
    }
  });

  test('a malformed handle is an error, not silently dropped', () {
    expect(
      () => BridgeConfig.fromEnvironment({
        ...base,
        'ALLOWED_HANDLES': 'CT-ABCD-EFGH,bob',
      }),
      throwsA(isA<ConfigException>()),
    );
  });

  test('missing agent URL / bad numbers / bad URL', () {
    expect(
      () => BridgeConfig.fromEnvironment({...base}..remove('A2A_AGENT_URL')),
      throwsA(isA<ConfigException>()),
    );
    expect(
      () => BridgeConfig.fromEnvironment({...base, 'A2A_POLL_SECONDS': '0'}),
      throwsA(isA<ConfigException>()),
    );
    expect(
      () => BridgeConfig.fromEnvironment({...base, 'A2A_AGENT_URL': 'ftp://x'}),
      throwsA(isA<ConfigException>()),
    );
  });

  test(
    'resolution: unknown handles skipped, none resolved refuses start',
    () async {
      final logs = <String>[];
      final ids = await resolveAllowedHandles(
        {'CT-AAAA-AAAA', 'CT-BBBB-BBBB'},
        (h) async => h == 'CT-AAAA-AAAA' ? 'ABC-ID' : null,
        log: logs.add,
      );
      expect(ids, {'abc-id': 'CT-AAAA-AAAA'});
      expect(logs.single, contains('CT-BBBB-BBBB'));

      await expectLater(
        resolveAllowedHandles({'CT-AAAA-AAAA'}, (_) async => null),
        throwsA(isA<ConfigException>()),
      );
    },
  );
}
