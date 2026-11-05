import 'dart:io';

import 'package:calltype_bot/calltype_bot.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// `postToChannel`: a bot publishing into a channel it is a publisher of.
/// The server is the authority on rights, suspension and the daily limit, so
/// these tests check resolution, the request shape and the error mapping.
void main() {
  const channelId = '00000000-0000-4000-8000-0000000000d0';
  const channelHandle = 'CH-NEWS-0001';
  late Directory dir;
  late FakeApi api;
  late CallTypeBot bot;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('calltype_bot_channel_test');
    api = await FakeApi.start();
    final channel = {
      'channelId': channelId,
      'handle': channelHandle,
      'name': 'News',
      'role': 'publisher',
    };
    api.channels[channelId] = channel;
    api.channels[channelHandle] = channel;
    bot = await CallTypeBot.start(
      apiBaseUrl: api.url,
      storePath: '${dir.path}/bot.store',
      storeKeyBase64: testStoreKey,
      transportFactory: (_, _) => FakeHub(),
      log: (_) {},
    );
  });

  tearDown(() async {
    await bot.close();
    await api.close();
    await dir.delete(recursive: true);
  });

  final guid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  test('by handle (any case): resolved, text post with a fresh GUID', () async {
    final postId = await bot.postToChannel(' ch-news-0001 ', 'Weekly digest');
    expect(postId, matches(guid));
    final post = api.channelPosts.single;
    expect(post.channelId, channelId);
    expect(post.body['postId'], postId);
    expect(post.body['kind'], 'text');
    expect(post.body['body'], 'Weekly digest');
    expect(api.requests, contains('GET /channels/ch-news-0001'));
  });

  test('by id: every post gets its own id', () async {
    final first = await bot.postToChannel(channelId, 'one');
    final second = await bot.postToChannel(channelId, 'two');
    expect(first, isNot(second));
    expect(api.channelPosts.map((p) => p.channelId), [channelId, channelId]);
  });

  Matcher refused(int status, String? code) => throwsA(
    isA<BotSendException>()
        .having((e) => e.statusCode, 'statusCode', status)
        .having((e) => e.code, 'code', code),
  );

  test('server refusals carry status and code', () async {
    api.channelPostFailures.addAll([
      (403, {'error': 'Channel is suspended.', 'code': 'channel_suspended'}),
      (429, {'error': 'Daily limit.', 'code': 'bot_post_limit'}),
      (403, null), // not owner/admin/publisher: the server sends no body
    ]);
    await expectLater(
      bot.postToChannel(channelId, 'x'),
      refused(403, channelSuspendedCode),
    );
    await expectLater(
      bot.postToChannel(channelId, 'x'),
      refused(429, botPostLimitCode),
    );
    await expectLater(bot.postToChannel(channelId, 'x'), refused(403, null));
    expect(api.channelPosts, isEmpty);
  });

  test('unknown channel -> 404 BotSendException, nothing posted', () async {
    await expectLater(
      bot.postToChannel('CH-NOPE-0000', 'x'),
      refused(404, null),
    );
    expect(api.requests.where((r) => r.startsWith('POST /channels')), isEmpty);
  });

  test(
    'empty target, blank or too long text: ArgumentError, no request',
    () async {
      final before = api.requests.length;
      await expectLater(bot.postToChannel(' ', 'x'), throwsArgumentError);
      await expectLater(
        bot.postToChannel(channelId, '  '),
        throwsArgumentError,
      );
      await expectLater(
        bot.postToChannel(channelId, 'x' * (channelPostMaxChars + 1)),
        throwsArgumentError,
      );
      expect(api.requests.length, before);
      // Exactly the limit is fine.
      await bot.postToChannel(channelId, 'x' * channelPostMaxChars);
      expect(api.channelPosts, hasLength(1));
    },
  );

  test('a 5xx is not a refusal: rethrown as is (caller may retry)', () async {
    api.channelPostFailures.add((503, null));
    await expectLater(
      bot.postToChannel(channelId, 'x'),
      throwsA(isNot(isA<BotSendException>())),
    );
  });
}
