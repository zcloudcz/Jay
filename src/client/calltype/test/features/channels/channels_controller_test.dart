import 'dart:convert';
import 'dart:typed_data';

import 'package:calltype/features/channels/channels_controller.dart';
import 'package:calltype_core/network/channel_dtos.dart';
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
    expect(h.controller.totalUnread, 1);
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

  test('reaction and vote totals are updated locally', () async {
    await followNews();
    await h.emitPost(postEvent('p1'));
    var post = await h.db.select(h.db.channelPosts).getSingle();

    await h.controller.react(post, '👍');
    post = await h.db.select(h.db.channelPosts).getSingle();
    expect(jsonDecode(post.reactions), {'👍': 1});
    expect(post.myReaction, '👍');

    await h.controller.react(post, '❤️'); // change
    post = await h.db.select(h.db.channelPosts).getSingle();
    expect(jsonDecode(post.reactions), {'❤️': 1});

    await h.controller.react(post, '❤️'); // same again = remove
    post = await h.db.select(h.db.channelPosts).getSingle();
    expect(jsonDecode(post.reactions), isEmpty);
    expect(post.myReaction, isNull);
    expect(h.api.calls.last, 'react p1 null');

    await h.controller.vote(post, 1);
    post = await h.db.select(h.db.channelPosts).getSingle();
    await h.controller.vote(post, 0); // changing the vote moves it
    post = await h.db.select(h.db.channelPosts).getSingle();
    expect(jsonDecode(post.pollVotes), [1, 0]);
    expect(post.myVote, 0);
  });

  test('oversized image is rejected before any upload', () async {
    await followNews();
    await expectLater(
      h.controller.publish(
        'c1',
        kind: 'image',
        body: '',
        imageBytes: Uint8List(channelImageMaxBytes + 1),
      ),
      throwsFormatException,
    );
    expect(h.api.calls.where((c) => c.startsWith('post ')), isEmpty);
  });
}
