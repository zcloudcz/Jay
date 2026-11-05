import 'package:a2a_bridge/a2a_bridge.dart';
import 'package:test/test.dart';

void main() {
  group('command normalization', () {
    test('ids become ^[a-z0-9_]{1,32}\$', () {
      expect(normalizeCommand('toolset.web'), 'toolset_web');
      expect(normalizeCommand('Summarize-Doc!'), 'summarize_doc');
      expect(normalizeCommand('  __a..b__ '), 'a_b');
      expect(normalizeCommand('x' * 40), 'x' * 32);
      expect(normalizeCommand('${'a' * 31}.b'), 'a' * 31);
      expect(normalizeCommand('!!!'), isNull);
      expect(normalizeCommand('dotaz-čeština'), 'dotaz_e_tina');
    });

    test('menu: reset first, dedupe, name fallback, description rules', () {
      final menu = commandsFromSkills([
        const A2aSkill(
          id: 'web.search',
          name: 'Search',
          description: 'Find\n  things',
        ),
        const A2aSkill(id: 'web-search', name: 'Search 2'),
        const A2aSkill(id: '***', name: 'Translate It'),
        const A2aSkill(id: '!!!', name: '???'),
        A2aSkill(id: 'long', name: 'Long', description: 'd' * 150),
      ]);
      expect(menu.commands.map((c) => c.command), [
        'reset',
        'web_search',
        'web_search_2',
        'translate_it',
        'long',
      ]);
      expect(menu.commands[1].description, 'Find things');
      expect(menu.commands[2].description, 'Search 2');
      expect(menu.commands[4].description.length, 100);
      expect(menu.commands[4].description, endsWith('...'));
      expect(menu.skills['web_search_2']!.id, 'web-search');
      for (final c in menu.commands) {
        expect(commandPattern.hasMatch(c.command), isTrue);
      }
    });

    test('at most 50 commands', () {
      final menu = commandsFromSkills([
        for (var i = 0; i < 80; i++) A2aSkill(id: 's$i', name: 's$i'),
      ]);
      expect(menu.commands, hasLength(maxCommands));
    });

    test('slash parsing', () {
      expect(parseSlashCommand('/reset'), (command: 'reset', args: ''));
      expect(parseSlashCommand('/Web_Search@CT-ABCD-EFGH  cats\nand dogs '), (
        command: 'web_search',
        args: 'cats\nand dogs',
      ));
      expect(parseSlashCommand('hello /reset'), isNull);
      expect(parseSlashCommand('/ nope'), isNull);
    });
  });

  group('wire parsing', () {
    test('task states of both versions', () {
      expect(
        parseTaskState('TASK_STATE_INPUT_REQUIRED'),
        TaskState.inputRequired,
      );
      expect(parseTaskState('input-required'), TaskState.inputRequired);
      expect(
        parseTaskState('TASK_STATE_AUTH_REQUIRED'),
        TaskState.authRequired,
      );
      expect(parseTaskState('auth-required'), TaskState.authRequired);
      expect(parseTaskState('canceled'), TaskState.canceled);
      expect(parseTaskState('TASK_STATE_REJECTED'), TaskState.rejected);
      expect(parseTaskState('TASK_STATE_UNSPECIFIED'), TaskState.unknown);
      expect(parseTaskState(null), TaskState.unknown);
    });

    test('results: wrapped and bare, task and message', () {
      final wrappedMsg = parseSendResult({
        'message': {
          'parts': [
            {'text': 'a'},
          ],
          'contextId': 'c',
        },
      });
      expect(wrappedMsg, isA<A2aMessage>().having((m) => m.text, 'text', 'a'));
      expect(wrappedMsg!.contextId, 'c');

      final bareMsg = parseSendResult({
        'kind': 'message',
        'role': 'agent',
        'parts': [
          {'kind': 'text', 'text': 'b'},
        ],
      });
      expect(bareMsg, isA<A2aMessage>().having((m) => m.text, 'text', 'b'));

      final bareTask = parseSendResult({
        'id': 't',
        'status': {'state': 'TASK_STATE_WORKING'},
      });
      expect(
        bareTask,
        isA<A2aTask>().having((t) => t.state, 'state', TaskState.working),
      );
      expect(parseSendResult('nope'), isNull);
      expect(parseSendResult(<String, dynamic>{}), isNull);
    });

    test('build user message for both versions', () {
      expect(
        buildUserMessage(
          A2aVersion.v1,
          messageId: 'm',
          text: 't',
          contextId: 'c',
        ),
        {
          'messageId': 'm',
          'role': 'ROLE_USER',
          'parts': [
            {'text': 't'},
          ],
          'contextId': 'c',
        },
      );
      expect(
        buildUserMessage(
          A2aVersion.v03,
          messageId: 'm',
          text: 't',
          taskId: 'x',
        ),
        {
          'kind': 'message',
          'messageId': 'm',
          'role': 'user',
          'parts': [
            {'kind': 'text', 'text': 't'},
          ],
          'taskId': 'x',
        },
      );
    });

    test(
      'v0.3 additionalInterfaces is used when preferred is not JSON-RPC',
      () {
        final card = parseAgentCard({
          'name': 'n',
          'protocolVersion': '0.3.0',
          'url': 'https://a.example/grpc',
          'preferredTransport': 'GRPC',
          'additionalInterfaces': [
            {'url': 'https://a.example/jsonrpc', 'transport': 'JSONRPC'},
          ],
        }, Uri.parse('https://a.example/.well-known/agent-card.json'));
        expect(card.endpoint.toString(), 'https://a.example/jsonrpc');
        expect(card.preferredVersion, A2aVersion.v03);
      },
    );

    test('relative endpoint resolves against the card, tenant kept', () {
      final card = parseAgentCard({
        'name': 'n',
        'supportedInterfaces': [
          {
            'url': '/a2a/v1',
            'protocolBinding': 'JSONRPC',
            'protocolVersion': '1.0',
            'tenant': 'acme',
          },
        ],
      }, Uri.parse('https://a.example/.well-known/agent-card.json'));
      expect(card.endpoint.toString(), 'https://a.example/a2a/v1');
      expect(card.tenant, 'acme');
    });
  });

  test('splitMessage keeps chunks under the limit and words whole', () {
    final chunks = splitMessage('aaa bbb ccc ddd', limit: 8);
    expect(chunks, ['aaa bbb', 'ccc ddd']);
  });
}
