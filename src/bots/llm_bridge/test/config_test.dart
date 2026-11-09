import 'package:llm_bridge/llm_bridge.dart';
import 'package:test/test.dart';

void main() {
  const base = {
    'CALLTYPE_API_URL': 'https://api.example.invalid/',
    'ALLOWED_HANDLES': 'ct-aaaa-0001, CT-BBBB-0002',
    'BOT_STORE_PATH': '/tmp/x/bot.store',
  };

  LlmConfig parse(Map<String, String> extra) =>
      LlmConfig.fromEnvironment({...base, ...extra});

  Matcher configError(String text) => throwsA(
    isA<ConfigException>().having((e) => e.message, 'message', contains(text)),
  );

  test('anthropic defaults', () {
    final c = parse({'LLM_PROVIDER': 'anthropic', 'ANTHROPIC_API_KEY': 'k'});
    expect(c.provider, LlmProviderKind.anthropic);
    expect(c.model, 'claude-sonnet-5-5');
    expect(c.effort, 'low');
    expect(c.baseUrl, 'https://api.anthropic.com');
    expect(c.apiUrl, 'https://api.example.invalid');
    expect(c.allowedHandles, {'CT-AAAA-0001', 'CT-BBBB-0002'});
    expect(c.historyMessages, 20);
    expect(c.maxTokens, 8192);
    expect(c.displayName, 'Jay bot');
    expect(c.systemPrompt, contains('Jay bot'));
    expect(c.statePath, '/tmp/x/bot.store.llm');
    expect(c.greeting, isTrue);
    expect(buildProvider(c), isA<AnthropicProvider>());
  });

  test('anthropic without a key is refused with a hint', () {
    expect(
      () => parse({'LLM_PROVIDER': 'anthropic'}),
      configError('ANTHROPIC_API_KEY'),
    );
  });

  test('openai official: key required, default model and effort', () {
    expect(
      () => parse({'LLM_PROVIDER': 'openai'}),
      configError('OPENAI_API_KEY'),
    );
    final c = parse({'LLM_PROVIDER': 'openai', 'OPENAI_API_KEY': 'k'});
    expect(c.model, 'gpt-6.1-sol');
    expect(c.effort, 'low');
    expect(c.baseUrl, 'https://api.openai.com/v1');
  });

  test('openai-compatible: no key needed, model required, no effort', () {
    expect(
      () => parse({
        'LLM_PROVIDER': 'openai',
        'OPENAI_BASE_URL': 'http://localhost:11434/v1',
      }),
      configError('LLM_MODEL'),
    );
    final c = parse({
      'LLM_PROVIDER': 'openai',
      'OPENAI_BASE_URL': 'http://localhost:11434/v1/',
      'LLM_MODEL': 'llama3.3',
    });
    expect(c.apiKey, isNull);
    expect(c.effort, isNull);
    expect(c.baseUrl, 'http://localhost:11434/v1');
    final o = buildProvider(c) as OpenAiProvider;
    expect(o.model, 'llama3.3');
  });

  test('LLM_EFFORT overrides; none switches it off', () {
    expect(
      parse({
        'LLM_PROVIDER': 'anthropic',
        'ANTHROPIC_API_KEY': 'k',
        'LLM_EFFORT': 'medium',
      }).effort,
      'medium',
    );
    expect(
      parse({
        'LLM_PROVIDER': 'anthropic',
        'ANTHROPIC_API_KEY': 'k',
        'LLM_EFFORT': 'none',
      }).effort,
      isNull,
    );
  });

  test('cli providers need no key; binaries and work dir default', () {
    final claude = parse({'LLM_PROVIDER': 'claude-cli'});
    expect(claude.apiKey, isNull);
    expect(claude.model, isNull);
    expect(claude.cliBinary, 'claude');
    expect(claude.cliWorkDir, '/tmp/x/bot.store.cli');
    expect(buildProvider(claude), isA<ClaudeCliProvider>());
    final codex = parse({
      'LLM_PROVIDER': 'codex-cli',
      'CODEX_BIN': '/opt/codex',
    });
    expect(codex.cliBinary, '/opt/codex');
    expect(buildProvider(codex), isA<CodexCliProvider>());
  });

  test('missing or unknown provider names the valid ones', () {
    expect(
      () => parse({}),
      configError('anthropic, openai, claude-cli, codex-cli'),
    );
    expect(
      () => parse({'LLM_PROVIDER': 'gemini'}),
      configError('"gemini" is unknown'),
    );
  });

  test('ALLOWED_HANDLES is fail-closed', () {
    expect(
      () => LlmConfig.fromEnvironment({
        ...base,
        'ALLOWED_HANDLES': ' , ',
        'LLM_PROVIDER': 'claude-cli',
      }),
      configError('refusing to start'),
    );
    expect(
      () => LlmConfig.fromEnvironment({
        ...base,
        'ALLOWED_HANDLES': 'CT-AAAA-0001,martin',
        'LLM_PROVIDER': 'claude-cli',
      }),
      configError('"MARTIN" is not a Jay handle'),
    );
  });

  test('missing API URL and bad numbers are clear errors', () {
    expect(
      () => LlmConfig.fromEnvironment({
        'ALLOWED_HANDLES': 'CT-AAAA-0001',
        'LLM_PROVIDER': 'claude-cli',
      }),
      configError('CALLTYPE_API_URL'),
    );
    expect(
      () => parse({'LLM_PROVIDER': 'claude-cli', 'LLM_HISTORY_MESSAGES': '-1'}),
      configError('LLM_HISTORY_MESSAGES'),
    );
    expect(
      () =>
          parse({'LLM_PROVIDER': 'claude-cli', 'CALLTYPE_API_URL': 'ftp://x'}),
      configError('http(s) URL'),
    );
    expect(
      () => parse({'LLM_PROVIDER': 'claude-cli', 'BOT_GREETING': 'maybe'}),
      configError('BOT_GREETING'),
    );
  });

  test('custom prompt, name, history, greeting off', () {
    final c = parse({
      'LLM_PROVIDER': 'claude-cli',
      'BOT_DISPLAY_NAME': 'Pepa',
      'LLM_SYSTEM_PROMPT': 'Mluv jako pirát.',
      'LLM_HISTORY_MESSAGES': '0',
      'BOT_GREETING': 'off',
    });
    expect(c.displayName, 'Pepa');
    expect(c.systemPrompt, 'Mluv jako pirát.');
    expect(c.historyMessages, 0);
    expect(c.greeting, isFalse);
  });

  test('resolveAllowedHandles: unknown skipped, none known refused', () async {
    final logs = <String>[];
    final ids = await resolveAllowedHandles(
      {'CT-AAAA-0001', 'CT-ZZZZ-9999'},
      (h) async => h == 'CT-AAAA-0001' ? 'ABC-ID' : null,
      log: logs.add,
    );
    expect(ids, {'abc-id': 'CT-AAAA-0001'});
    expect(logs.single, contains('CT-ZZZZ-9999'));
    await expectLater(
      resolveAllowedHandles({'CT-ZZZZ-9999'}, (_) async => null),
      throwsA(isA<ConfigException>()),
    );
  });

  test('bot access: GROUP_REPLIES, BOT_INBOUND, PEER_MAX_TURNS_CAP', () {
    final cli = {'LLM_PROVIDER': 'claude-cli'};
    final d = parse(cli);
    // Subscription CLIs answer only owners unless opted in; API keys
    // answer members of owner groups by default.
    expect(d.groupReplies, GroupReplies.owners);
    expect(
      parse({
        'LLM_PROVIDER': 'anthropic',
        'ANTHROPIC_API_KEY': 'k',
      }).groupReplies,
      GroupReplies.members,
    );
    expect(
      parse({...cli, 'GROUP_REPLIES': 'members'}).groupReplies,
      GroupReplies.members,
    );
    expect(d.inbound, isNull);
    expect(d.peerTurnsCap, 50);
    final c = parse({
      ...cli,
      'GROUP_REPLIES': 'Owners',
      'BOT_INBOUND': 'open',
      'PEER_MAX_TURNS_CAP': '0',
    });
    expect(c.groupReplies, GroupReplies.owners);
    expect(c.inbound, 'open');
    expect(c.peerTurnsCap, 0);
    expect(
      () => parse({...cli, 'GROUP_REPLIES': 'all'}),
      configError('GROUP_REPLIES must be members or owners'),
    );
    expect(
      () => parse({...cli, 'BOT_INBOUND': 'everyone'}),
      configError('BOT_INBOUND must be owners or open'),
    );
  });
}
