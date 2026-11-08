import 'package:calltype_core/network/api_client.dart';
import 'package:calltype/features/chat/bot_commands.dart';
import 'package:calltype/features/chat/mentions.dart';
import 'package:calltype/features/contacts/bot_link.dart';
import 'package:calltype_core/network/bot_dtos.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure logic of agent messaging in the app (contract section 8).
void main() {
  group('mentionedIds', () {
    const hermes = (token: 'Hermes', id: 'id-hermes');
    const ann = (token: 'Ann Smith', id: 'id-ann');

    test('reports picked mentions still in the text', () {
      expect(mentionedIds('@Hermes deploy and ask @Ann Smith', [hermes, ann]), [
        'id-hermes',
        'id-ann',
      ]);
    });

    test('a token removed after picking is not reported', () {
      expect(mentionedIds('deploy please', [hermes]), isEmpty);
      expect(mentionedIds('Hermes without the at', [hermes]), isEmpty);
    });

    test('needs word boundaries on both sides', () {
      expect(mentionedIds('@HermesBackup go', [hermes]), isEmpty);
      expect(mentionedIds('mail@Hermes', [hermes]), isEmpty);
      expect(mentionedIds('@Hermes, go', [hermes]), ['id-hermes']);
      expect(mentionedIds('hi\n@Hermes', [hermes]), ['id-hermes']);
    });

    test('the same member picked twice is reported once', () {
      expect(mentionedIds('@Hermes @Hermes', [hermes, hermes]), ['id-hermes']);
    });

    test('buildMentionCandidates carries the member identity id', () {
      final c = buildMentionCandidates(
        members: const [
          GroupMemberInfo(
            deviceId: 'b0000000-0000-4000-8000-000000000001',
            userHandle: 'CT-AAAA-BBBB',
            displayName: 'Hermes',
            isBot: true,
          ),
        ],
        contacts: const [],
        myIdentityId: 'me',
      ).single;
      expect(c.token, 'Hermes');
      expect(c.id, 'b0000000-0000-4000-8000-000000000001');
    });
  });

  group('activeCommandQuery', () {
    test('only a slash that opens the text, while in the first word', () {
      expect(activeCommandQuery('/', 1), '');
      expect(activeCommandQuery('/he', 3), 'he');
      expect(activeCommandQuery('/help ', 6), isNull);
      expect(activeCommandQuery('and/or', 6), isNull);
      expect(activeCommandQuery(' /help', 6), isNull);
      expect(activeCommandQuery('', 0), isNull);
    });
  });

  group('buildCommandSuggestions', () {
    const commands = {
      'bot-1': [
        BotCommand(command: 'help', description: 'Show help'),
        BotCommand(command: 'Bad Command', description: 'invalid'),
      ],
      'bot-2': [BotCommand(command: 'help', description: 'Other help')],
    };

    test('1:1 inserts /cmd with a trailing space', () {
      final s = buildCommandSuggestions(
        bots: const [CommandBot(deviceId: 'bot-1')],
        commands: commands,
        group: false,
      );
      expect(s.map((c) => c.insert), ['/help ']);
      expect(s.single.botName, isNull);
    });

    test('a group names the bot: /cmd@HANDLE, bots without handle skipped', () {
      final s = buildCommandSuggestions(
        bots: const [
          CommandBot(deviceId: 'bot-1', handle: 'CT-AAAA-1111', name: 'Hermes'),
          CommandBot(deviceId: 'bot-2', handle: 'CT-BBBB-2222'),
          CommandBot(deviceId: 'bot-3'),
        ],
        commands: commands,
        group: true,
      );
      expect(s.map((c) => c.insert), [
        '/help@CT-AAAA-1111 ',
        '/help@CT-BBBB-2222 ',
      ]);
      expect(s.map((c) => c.botName), ['Hermes', 'CT-BBBB-2222']);
    });

    test('filterCommands matches the command prefix only', () {
      final all = buildCommandSuggestions(
        bots: const [CommandBot(deviceId: 'bot-1')],
        commands: {
          'bot-1': const [
            BotCommand(command: 'help', description: 'Show help'),
            BotCommand(command: 'new', description: 'help with new'),
          ],
        },
        group: false,
      );
      expect(filterCommands(all, 'he').map((c) => c.command), ['help']);
      expect(filterCommands(all, '').length, 2);
      expect(filterCommands(all, 'HE@CT-X').map((c) => c.command), ['help']);
    });
  });

  group('BotCommandsCache', () {
    test('caches per bot for 10 minutes, then fetches again', () async {
      var now = DateTime(2026, 11, 5, 12);
      final cache = BotCommandsCache(now: () => now);
      final calls = <String>[];
      Future<List<BotCommand>> fetch(String id) async {
        calls.add(id);
        return const [BotCommand(command: 'help', description: 'Help')];
      }

      await cache.get('bot-1', fetch);
      await cache.get('BOT-1', fetch);
      now = now.add(const Duration(minutes: 9, seconds: 59));
      await cache.get('bot-1', fetch);
      expect(calls, ['bot-1']);
      now = now.add(const Duration(seconds: 1));
      await cache.get('bot-1', fetch);
      expect(calls, ['bot-1', 'bot-1']);
    });

    test('a failure yields an empty menu and is not cached', () async {
      final cache = BotCommandsCache();
      var fail = true;
      Future<List<BotCommand>> fetch(String id) async {
        if (fail) throw StateError('offline');
        return const [BotCommand(command: 'help', description: 'Help')];
      }

      expect(await cache.get('bot-1', fetch), isEmpty);
      fail = false;
      expect(await cache.get('bot-1', fetch), hasLength(1));
    });
  });

  group('parseBotLink', () {
    test('handle and start payload', () {
      final link = parseBotLink('calltype://bot/CT-AB12-CD34?start=ref_42-x')!;
      expect(link.handle, 'CT-AB12-CD34');
      expect(link.start, 'ref_42-x');
      expect(link.startCommand, '/start ref_42-x');
      expect(botLinkRoute(link), '/bot/CT-AB12-CD34?start=ref_42-x');
    });

    test('lower-case handle is normalized, no payload = plain /start', () {
      final link = parseBotLink('  calltype://bot/ct-ab12-cd34 ')!;
      expect(link.handle, 'CT-AB12-CD34');
      expect(link.start, isNull);
      expect(link.startCommand, '/start');
      expect(botLinkRoute(link), '/bot/CT-AB12-CD34');
    });

    test('an invalid payload is ignored, the link still opens the bot', () {
      for (final bad in [
        'has space',
        'semi;colon',
        'x' * 65,
        '',
        '%2Fstart',
        'emoji\u{1F600}',
      ]) {
        final link = parseBotLink(
          'calltype://bot/CT-AB12-CD34?start=${Uri.encodeQueryComponent(bad)}',
        );
        expect(link, isNotNull, reason: bad);
        expect(link!.start, isNull, reason: bad);
      }
      expect(
        parseBotLink('calltype://bot/CT-AB12-CD34?start=${'x' * 64}')!.start,
        'x' * 64,
      );
    });

    test('anything that is not a bot link is null', () {
      expect(parseBotLink('calltype://channel/CH-AAAA-BBBB'), isNull);
      expect(parseBotLink('calltype://contact/CT-AB12-CD34'), isNull);
      expect(parseBotLink('https://bot/CT-AB12-CD34'), isNull);
      expect(parseBotLink('calltype://bot/'), isNull);
      expect(parseBotLink('calltype://bot/CT-AB12/extra'), isNull);
      expect(parseBotLink('calltype://bot/..%2Fsettings'), isNull);
      expect(parseBotLink('not a link'), isNull);
    });
  });
}
