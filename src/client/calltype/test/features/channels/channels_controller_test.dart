import 'dart:convert';
import 'dart:typed_data';

import 'package:calltype/features/channels/channels_controller.dart';
import 'package:calltype_core/network/channel_dtos.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_channels.dart';

void main() {
  late ChannelHarness h;
  setUp(() => h = ChannelHarness());
  tearDown(() => h.dispose());

  Future<void> followNews() async {
    h.api.profiles[news.handle] = news;
    await h.controller.follow(await h.controller.openByHandle(news.handle));
  }

  test('a channel appears only after an explicit follow', () async {
    await h.controller.load();
    expect(h.controller.channels, isEmpty);

    await followNews();

    expect(h.controller.channels.single.name, 'News');
    expect(h.controller.channels.single.isFollowing, isTrue);
    expect(h.api.calls, contains('follow c1'));
    // Live delivery needs the hub group → joined right after following.
    expect(h.hubCalls, ['JoinChannels']);
  });

  test('hub post is stored once; a duplicate event is ignored', () async {
    await followNews();

    await h.emitPost(postEvent('p1'));
    await h.emitPost(postEvent('p1'));
    // Back-to-back replay without awaiting in between (reconnect burst).
    h.postEvents
      ..add(postEvent('p2'))
      ..add(postEvent('p2'));
    await Future<void>.delayed(Duration.zero);
    await h.controller.idle;

    final posts = await h.db.select(h.db.channelPosts).get();
    expect(posts.map((p) => p.postId), unorderedEquals(['p1', 'p2']));
    expect(h.controller.totalUnread, 2);
  });

  test('tombstone removes the post locally', () async {
    await followNews();
    await h.emitPost(postEvent('p1'));
    await h.emitPost(postEvent('p1', deleted: true));
    expect(await h.db.select(h.db.channelPosts).get(), isEmpty);
  });

  test('unread count: bumped by events, not for the open feed, reset on '
      'open', () async {
    await followNews();
    await h.emitPost(postEvent('p1'));
    expect(h.controller.totalUnread, 1);

    await h.controller.setOpenChannel('c1');
    expect(h.controller.totalUnread, 0);
    await h.emitPost(postEvent('p2'));
    expect(h.controller.totalUnread, 0);

    await h.controller.setOpenChannel(null);
    await h.emitPost(postEvent('p3'));
    expect(h.controller.totalUnread, 1);
  });

  test('blocked channel: unfollowed, wiped, ignores events and cannot be '
      'reopened from a link until unblocked', () async {
    await followNews();
    await h.emitPost(postEvent('p1'));

    await h.controller.block(channelId: 'c1', handle: news.handle, name: 'N');

    expect(h.api.calls, contains('unfollow c1'));
    expect(h.hubCalls, contains('LeaveChannel c1'));
    expect(h.controller.channels, isEmpty);
    expect(await h.db.select(h.db.channelPosts).get(), isEmpty);

    await h.emitPost(postEvent('p2'));
    expect(await h.db.select(h.db.channelPosts).get(), isEmpty);

    // Link / QR / typed handle — case-insensitively — is refused...
    await expectLater(
      h.controller.openByHandle(news.handle.toLowerCase()),
      throwsA(isA<ChannelBlockedException>()),
    );
    // ...and the blocked channel is not resurrected by a sync either.
    h.api.mine = [news];
    await h.controller.sync();
    expect(h.controller.channels, isEmpty);

    await h.controller.unblock('c1');
    expect((await h.controller.openByHandle(news.handle)).channelId, 'c1');
  });

  test('blocking works offline (unfollow fails)', () async {
    await followNews();
    h.api.failUnfollow = true;
    await h.controller.block(channelId: 'c1', handle: news.handle, name: 'N');
    expect(h.controller.isBlocked(channelId: 'c1'), isTrue);
    expect(h.controller.channels, isEmpty);
  });

  test('events of a channel that is not followed are dropped', () async {
    await h.controller.load();
    await h.emitPost(postEvent('p1', channelId: 'stranger'));
    expect(await h.db.select(h.db.channelPosts).get(), isEmpty);
  });

  test('sync fetches posts only for channels with unread > 0, using the '
      'newest local post as cursor, then joins hub groups', () async {
    await followNews();
    await h.emitPost(postEvent('p1', createdAt: '2026-09-17T10:00:00.123Z'));
    h.api.calls.clear();
    h.hubCalls.clear();
    const quiet = ChannelInfo(channelId: 'c2', handle: 'CH-QUIET', name: 'Q');
    h.api.mine = [
      const ChannelInfo(
        channelId: 'c1',
        handle: 'CH-NEWS-0001',
        name: 'News',
        unreadCount: 1,
      ),
      quiet,
    ];
    h.api.posts['c1'] = [
      ChannelPostDto(
        channelId: 'c1',
        postId: 'p2',
        createdAt: DateTime.utc(2026, 9, 17, 11),
      ),
    ];

    await h.controller.sync();

    expect(h.api.calls, [
      'mine',
      // Full-precision cursor, exactly as received.
      'posts c1 after=2026-09-17T10:00:00.123Z',
    ]);
    expect(h.hubCalls, ['JoinChannels']);
    expect(h.controller.channels.map((c) => c.channelId), ['c1', 'c2']);
    // p1 (hub, still unread) + p2 (caught up).
    expect(h.controller.totalUnread, 2);
    expect(await h.db.select(h.db.channelPosts).get(), hasLength(2));
  });

  test('sync drops channels that are no longer listed by the server', () async {
    await followNews();
    h.api.mine = [];
    await h.controller.sync();
    expect(h.controller.channels, isEmpty);
  });

  test('ChannelDeleted removes the channel and its posts', () async {
    await followNews();
    await h.emitPost(postEvent('p1'));
    h.deletedEvents.add({'channelId': 'c1'});
    await Future<void>.delayed(Duration.zero);
    await h.controller.idle;
    expect(h.controller.channels, isEmpty);
    expect(await h.db.select(h.db.channelPosts).get(), isEmpty);
  });

  test('unfollow removes a follower copy and leaves the hub group', () async {
    await followNews();
    await h.controller.unfollow('c1');
    expect(h.controller.channels, isEmpty);
    expect(h.hubCalls, contains('LeaveChannel c1'));
  });

  test('channel posts never touch chat tables or the chat list', () async {
    await followNews();
    await h.emitPost(postEvent('p1'));
    await h.controller.publish('c1', kind: 'text', body: 'from admin');

    expect(await h.db.select(h.db.channelPosts).get(), hasLength(2));
    expect(await h.db.select(h.db.messages).get(), isEmpty);
    expect(await h.db.select(h.db.conversations).get(), isEmpty);
  });

  test(
    'reaction and vote apply the SERVER totals, not a local guess',
    () async {
      await followNews();
      await h.emitPost(postEvent('p1'));
      var post = await h.db.select(h.db.channelPosts).getSingle();

      // Others reacted meanwhile: the response knows, the cache does not.
      h.api.totals = const ChannelPostTotals(
        reactions: {'👍': 5, '❤️': 2},
        myReaction: '👍',
      );
      await h.controller.react(post, '👍');
      post = await h.db.select(h.db.channelPosts).getSingle();
      expect(jsonDecode(post.reactions), {'👍': 5, '❤️': 2});
      expect(post.myReaction, '👍');

      // Same emoji again = remove (DELETE), totals again from the response.
      h.api.totals = const ChannelPostTotals(reactions: {'👍': 4, '❤️': 2});
      await h.controller.react(post, '👍');
      post = await h.db.select(h.db.channelPosts).getSingle();
      expect(h.api.calls.last, 'react p1 null');
      expect(jsonDecode(post.reactions), {'👍': 4, '❤️': 2});
      expect(post.myReaction, isNull);

      h.api.totals = const ChannelPostTotals(pollVotes: [3, 0, 8], myVote: 2);
      await h.controller.vote(post, 2);
      post = await h.db.select(h.db.channelPosts).getSingle();
      expect(jsonDecode(post.pollVotes), [3, 0, 8]);
      expect(post.myVote, 2);
    },
  );

  test('publish stores the post the server returned', () async {
    await followNews();
    await h.controller.publish('c1', kind: 'text', body: 'hi');
    final post = await h.db.select(h.db.channelPosts).getSingle();
    // The server's createdAt is the paging cursor — never the local clock.
    expect(post.createdAt, h.api.serverNow.toIso8601String());
  });

  group('catch-up paging', () {
    List<ChannelPostDto> serverPosts(int count) => [
      for (var i = 1; i <= count; i++)
        ChannelPostDto(
          channelId: 'c1',
          postId: 's$i',
          createdAt: DateTime.utc(2026, 9, 17, 11).add(Duration(seconds: i)),
        ),
    ];
    const unread = ChannelInfo(
      channelId: 'c1',
      handle: 'CH-NEWS-0001',
      name: 'News',
      unreadCount: 9,
    );

    test('walks forward page by page until a short page', () async {
      await followNews();
      await h.emitPost(postEvent('p1'));
      h.api.posts['c1'] = serverPosts(120);
      h.api.mine = [unread];
      h.api.calls.clear();

      await h.controller.sync();

      expect(h.api.calls, [
        'mine',
        'posts c1 after=2026-09-17T10:00:00.000Z',
        'posts c1 after=2026-09-17T11:00:50.000Z', // newest of page 1
        'posts c1 after=2026-09-17T11:01:40.000Z', // newest of page 2
      ]);
      expect(await h.db.select(h.db.channelPosts).get(), hasLength(121));
      // 1 from the hub + 120 caught up — not the server's number, which
      // drops to 0 as soon as the posts were fetched.
      expect(h.controller.totalUnread, 121);
    });

    test('a cursor that does not advance cannot loop forever', () async {
      await followNews();
      await h.emitPost(postEvent('p1', createdAt: '2026-09-17T13:00:00.000Z'));
      h.api.posts['c1'] = serverPosts(ChannelsController.pageSize);
      h.api.stuck = true;
      h.api.mine = [unread];
      h.api.calls.clear();

      await h.controller.sync();

      expect(h.api.calls.where((c) => c.startsWith('posts')), hasLength(1));
    });

    test(
      'a later sync does not wipe the badge the server already forgot',
      () async {
        await followNews();
        h.api.posts['c1'] = serverPosts(3);
        h.api.mine = [unread];
        await h.controller.sync();
        expect(h.controller.totalUnread, 3);

        // Fetching marked everything as seen on the server.
        h.api.mine = [news];
        await h.controller.sync();
        expect(h.controller.totalUnread, 3);

        await h.controller.setOpenChannel('c1');
        expect(h.controller.totalUnread, 0);
      },
    );
  });

  group('tombstones', () {
    ChannelPostDto feedPost(String id, {bool deleted = false}) =>
        ChannelPostDto(
          channelId: 'c1',
          postId: id,
          body: deleted ? '' : 'text',
          createdAt: DateTime.utc(2026, 9, 17, 11),
          deleted: deleted,
        );

    test(
      'from the feed: removed, and never resurrected by later syncs',
      () async {
        await followNews();
        h.api.posts['c1'] = [feedPost('p1')];
        await h.controller.refresh('c1');
        expect(await h.db.select(h.db.channelPosts).get(), hasLength(1));

        // Deleted while this device was offline: the feed keeps a tombstone.
        h.api.posts['c1'] = [feedPost('p1', deleted: true)];
        await h.controller.refresh('c1');
        expect(await h.db.select(h.db.channelPosts).get(), isEmpty);

        // With the row gone the cursor moves back, so catch-up sees the
        // tombstone again — every time. It must stay gone and uncounted.
        h.api.mine = [
          const ChannelInfo(
            channelId: 'c1',
            handle: 'CH-NEWS-0001',
            name: 'News',
            unreadCount: 1,
          ),
        ];
        await h.controller.sync();
        await h.controller.sync();
        expect(await h.db.select(h.db.channelPosts).get(), isEmpty);
        expect(h.controller.totalUnread, 0);
      },
    );

    test('from the hub for an unknown post: nothing is stored', () async {
      await followNews();
      await h.emitPost(postEvent('ghost', deleted: true));
      expect(await h.db.select(h.db.channelPosts).get(), isEmpty);
      expect(h.controller.totalUnread, 0);
    });
  });

  test('owner: create uses the returned profile; edit keeps the unread '
      'badge; delete cleans up locally', () async {
    await h.controller.load();
    final created = await h.controller.createChannel('Mine', 'About');
    expect(created.handle, 'CH-NEW0-0001');
    expect(created.role, 'owner');
    expect(created.isFollowing, isFalse);

    await h.emitPost(postEvent('p1', channelId: 'new'));
    await h.controller.updateChannel('new', name: 'Renamed');
    expect(h.api.calls.last, 'patch new name=Renamed description=null');
    expect(h.controller.channel('new')!.name, 'Renamed');
    expect(h.controller.totalUnread, 1);

    await h.controller.deleteChannel('new');
    expect(h.api.calls.last, 'delete new');
    expect(h.hubCalls, contains('LeaveChannel new'));
    expect(h.controller.channels, isEmpty);
    expect(await h.db.select(h.db.channelPosts).get(), isEmpty);
  });

  test('server error codes map to user-facing messages', () {
    DioException failure(int status, Object? data) => DioException(
      requestOptions: RequestOptions(),
      response: Response(
        requestOptions: RequestOptions(),
        statusCode: status,
        data: data,
      ),
    );
    String message(int status, String code) =>
        channelErrorMessage(failure(status, {'error': 'x', 'code': code}));

    expect(message(403, 'account_required'), contains('registered account'));
    expect(message(409, 'channel_limit_reached'), contains('limit'));
    expect(message(409, 'poll_closed'), contains('closed'));
    expect(message(422, 'emoji_not_allowed'), contains('reaction'));
    expect(message(422, 'invalid_option_index'), contains('option'));
    expect(message(422, 'not_a_poll'), contains('option'));
    expect(message(429, 'report_limit_reached'), contains('reports'));
    expect(message(413, 'image_too_large'), contains('2 MiB'));
    expect(message(415, 'unsupported_image_type'), contains('JPEG'));
    expect(message(409, 'post_id_conflict'), contains('Try again'));
    // Role / non-follower 403: no body at all.
    expect(channelErrorMessage(failure(403, '')), contains('not allowed'));
    // Offline, unknown code, non-HTTP errors: the generic line.
    expect(message(500, 'whatever'), contains('connection'));
    expect(channelErrorMessage(StateError('x')), contains('connection'));
    expect(channelErrorMessage(const FormatException('Too big')), 'Too big');
  });

  test('unsupported image type is rejected before any upload', () async {
    await followNews();
    await expectLater(
      h.controller.publish(
        'c1',
        kind: 'image',
        body: '',
        imageBytes: Uint8List(10),
        imageName: 'drawing.svg',
      ),
      throwsFormatException,
    );
    expect(h.api.calls.where((c) => c.startsWith('post ')), isEmpty);
  });

  test('oversized image is rejected before any upload', () async {
    await followNews();
    await expectLater(
      h.controller.publish(
        'c1',
        kind: 'image',
        body: '',
        imageBytes: Uint8List(channelImageMaxBytes + 1),
        imageName: 'photo.png',
      ),
      throwsFormatException,
    );
    expect(h.api.calls.where((c) => c.startsWith('post ')), isEmpty);
  });
}
