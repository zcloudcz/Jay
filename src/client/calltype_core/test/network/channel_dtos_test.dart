import 'dart:convert';

import 'package:calltype_core/network/channel_dtos.dart';
import 'package:test/test.dart';

/// The channel DTOs were written against the plan while the server was built
/// in parallel, and channel posts are public input. Parsing therefore has to
/// tolerate missing optional fields instead of crashing the feed.
void main() {
  group('ChannelInfo', () {
    test('parses a full profile', () {
      final info = ChannelInfo.fromJson({
        'channelId': 'c1',
        'handle': 'CH-AAAA-BBBB',
        'name': 'News',
        'description': 'Daily',
        'followerCount': 12,
        'isFollowing': true,
        'role': 'owner',
        'unreadCount': 4,
      });
      expect(info.handle, 'CH-AAAA-BBBB');
      expect(info.followerCount, 12);
      expect(info.isFollowing, isTrue);
      expect(info.canPublish, isTrue);
      expect(info.unreadCount, 4);
    });

    test('missing optional fields fall back to defaults', () {
      final info = ChannelInfo.fromJson({'channelId': 'c1'});
      expect(info.name, '');
      expect(info.description, '');
      expect(info.followerCount, 0);
      expect(info.isFollowing, isFalse);
      expect(info.canPublish, isFalse);
      expect(info.unreadCount, 0);
    });

    test('accepts isAdmin flag instead of role and double counts', () {
      final info = ChannelInfo.fromJson({
        'channelId': 'c1',
        'isAdmin': true,
        'followerCount': 3.0,
      });
      expect(info.role, 'admin');
      expect(info.followerCount, 3);
    });
  });

  group('ChannelPostDto', () {
    test('parses a list item with reaction and vote totals', () {
      final post = ChannelPostDto.fromJson({
        'postId': 'p1',
        'kind': 'poll',
        'body': '{}',
        'createdAt': '2026-09-17T10:00:00.123Z',
        'reactions': {'👍': 2, '❤️': 1},
        'myReaction': '👍',
        'votes': {'0': 3, '1': 1},
        'myVote': 0,
      }, channelId: 'c1');
      expect(post.channelId, 'c1'); // taken from the URL, not the item
      expect(post.createdAt.isUtc, isTrue);
      expect(post.createdAt.millisecond, 123);
      expect(post.reactions, {'👍': 2, '❤️': 1});
      expect(post.pollVotes, [3, 1]);
      expect(post.myVote, 0);
      expect(post.deleted, isFalse);
    });

    test('hub event without optional fields does not crash', () {
      final post = ChannelPostDto.fromJson({'channelId': 'c1', 'postId': 'p1'});
      expect(post.kind, 'text');
      expect(post.body, '');
      expect(post.attachmentBlobPath, isNull);
      expect(post.reactions, isEmpty);
      expect(post.pollVotes, isEmpty);
      expect(post.myReaction, isNull);
      expect(post.myVote, isNull);
    });

    test('tombstone', () {
      final post = ChannelPostDto.fromJson({
        'channelId': 'c1',
        'postId': 'p1',
        'deleted': true,
      });
      expect(post.deleted, isTrue);
    });
  });

  // JSON below is what the server serialises (ChannelEndpoints.PostDto /
  // ChannelDto / TotalsResult, ChannelService.PostEvent): camelCase names,
  // DateTimeOffset as ISO-8601 with microseconds and a +00:00 offset.
  group('server wire format', () {
    Map<String, dynamic> json(String text) =>
        jsonDecode(text) as Map<String, dynamic>;

    test('feed post: sparse votes map keyed by option index', () {
      final post = ChannelPostDto.fromJson(
        json(
          '{"channelId":"3f2b8c1e-0000-4000-8000-000000000001",'
          '"postId":"3f2b8c1e-0000-4000-8000-000000000002","kind":"poll",'
          r'"body":"{\"question\":\"Lunch?\",\"options\":[\"a\",\"b\",\"c\"],\"closesAt\":null}",'
          '"attachmentBlobPath":null,'
          '"createdAt":"2026-09-17T10:00:00.123456+00:00","deleted":false,'
          '"reactions":{"👍":2},"myReaction":"👍",'
          '"votes":{"0":3,"2":1},"myVote":2}',
        ),
      );
      expect(post.pollVotes, [3, 0, 1]); // option 1 has no votes → absent
      expect(post.myVote, 2);
      expect(post.reactions, {'👍': 2});
      expect(post.createdAt, DateTime.utc(2026, 9, 17, 10, 0, 0, 123, 456));
      final poll = ChannelPoll.tryParse(post.body)!;
      expect(poll.options, ['a', 'b', 'c']);
      expect(poll.closesAt, isNull);
    });

    test('junk vote keys are ignored, not allocated', () {
      final post = ChannelPostDto.fromJson({
        'channelId': 'c1',
        'postId': 'p1',
        'votes': {'x': 1, '-1': 2, '999999999': 3, '1': 4},
      });
      expect(post.pollVotes, [0, 4]);
    });

    test('feed tombstone: blank body, no attachment, deleted', () {
      final post = ChannelPostDto.fromJson(
        json(
          '{"channelId":"c1","postId":"p1","kind":"image","body":"",'
          '"attachmentBlobPath":null,'
          '"createdAt":"2026-09-17T10:00:00+00:00","deleted":true,'
          '"reactions":{},"myReaction":null,"votes":{},"myVote":null}',
        ),
      );
      expect(post.deleted, isTrue);
      expect(post.body, '');
      expect(post.attachmentBlobPath, isNull);
    });

    test('hub event has no totals at all', () {
      final post = ChannelPostDto.fromJson(
        json(
          '{"channelId":"c1","postId":"p1","kind":"text","body":"hi",'
          '"attachmentBlobPath":null,'
          '"createdAt":"2026-09-17T10:00:00.5+00:00","deleted":false}',
        ),
      );
      expect(post.body, 'hi');
      expect(post.reactions, isEmpty);
      expect(post.pollVotes, isEmpty);
    });

    test('reaction / vote response carries fresh totals', () {
      final totals = ChannelPostTotals.fromJson(
        json(
          '{"postId":"p1","reactions":{"❤️":4,"👍":1},"myReaction":"❤️",'
          '"votes":{"1":7},"myVote":1}',
        ),
      );
      expect(totals.reactions, {'❤️': 4, '👍': 1});
      expect(totals.myReaction, '❤️');
      expect(totals.pollVotes, [0, 7]);
      expect(totals.myVote, 1);
      // Reaction removed, never voted.
      final empty = ChannelPostTotals.fromJson(
        json(
          '{"postId":"p1","reactions":{},"myReaction":null,'
          '"votes":{},"myVote":null}',
        ),
      );
      expect(empty.reactions, isEmpty);
      expect(empty.myReaction, isNull);
      expect(empty.myVote, isNull);
    });

    test('created channel is a full profile', () {
      final info = ChannelInfo.fromJson(
        json(
          '{"channelId":"c1","handle":"CH-AAAA-BBBB","name":"News",'
          '"description":"","followerCount":0,'
          '"createdAt":"2026-09-17T10:00:00+00:00","isFollowing":false,'
          '"role":"owner","unreadCount":0}',
        ),
      );
      expect(info.handle, 'CH-AAAA-BBBB');
      expect(info.role, 'owner');
      expect(info.isFollowing, isFalse);
    });

    test('admins list', () {
      final admins = parseList(
        jsonDecode(
          '[{"deviceId":"d1","addedAt":"2026-09-17T10:00:00+00:00"},'
          '{"deviceId":"d2"}]',
        ),
      ).map(ChannelAdminDto.fromJson).toList();
      expect(admins.map((a) => a.deviceId), ['d1', 'd2']);
      expect(admins.first.addedAt, DateTime.utc(2026, 9, 17, 10));
      expect(admins.last.addedAt, isNull);
    });

    test('upload response and error codes', () {
      expect(
        parseUploadedBlobPath(
          json(
            '{"blobPath":"channel-media/c1/0123456789abcdef0123456789abcdef.png",'
            '"name":"0123456789abcdef0123456789abcdef.png"}',
          ),
        ),
        'channel-media/c1/0123456789abcdef0123456789abcdef.png',
      );
      expect(
        parseErrorCode(
          json('{"error":"Poll is closed.","code":"poll_closed"}'),
        ),
        'poll_closed',
      );
      expect(parseErrorCode(json('{"error":"x","code":null}')), isNull);
      // Role / non-follower 403s have an empty body.
      expect(parseErrorCode(''), isNull);
      expect(parseErrorCode(null), isNull);
    });
  });

  test('image types the server accepts', () {
    expect(channelImageContentType('a.JPG'), 'image/jpeg');
    expect(channelImageContentType('a.b.webp'), 'image/webp');
    expect(channelImageContentType('a.gif'), 'image/gif');
    expect(channelImageContentType('a.svg'), isNull);
    expect(channelImageContentType('noextension'), isNull);
  });

  group('ChannelPoll', () {
    test('round-trips through the post body', () {
      final closesAt = DateTime.utc(2030);
      final poll = ChannelPoll.tryParse(
        ChannelPoll(
          question: 'Lunch?',
          options: const ['Pizza', 'Soup'],
          closesAt: closesAt,
        ).encode(),
      )!;
      expect(poll.question, 'Lunch?');
      expect(poll.options, ['Pizza', 'Soup']);
      expect(poll.closesAt, closesAt);
      expect(poll.closed, isFalse);
    });

    test('closesAt is optional; malformed bodies yield null', () {
      expect(
        ChannelPoll.tryParse('{"question":"Q","options":["a","b"]}')!.closesAt,
        isNull,
      );
      expect(ChannelPoll.tryParse('not json'), isNull);
      expect(ChannelPoll.tryParse('{"question":"Q"}'), isNull);
      expect(ChannelPoll.tryParse('[]'), isNull);
    });
  });

  test('request bodies omit absent optional fields', () {
    expect(createPostBody(postId: 'p', kind: 'text', body: 'hi'), {
      'postId': 'p',
      'kind': 'text',
      'body': 'hi',
    });
    expect(reportBody('spam'), {'reason': 'spam'});
    expect(reportBody('spam', postId: 'p'), {'postId': 'p', 'reason': 'spam'});
    expect(postsQuery(after: 'x'), {'after': 'x'});
    // PATCH: null = unchanged, so an untouched field is not sent at all.
    expect(updateChannelBody(name: 'New'), {'name': 'New'});
    expect(updateChannelBody(), isEmpty);
  });

  test('list parsing tolerates an envelope and junk', () {
    expect(
      parseList([
        {'a': 1},
        'junk',
      ]),
      hasLength(1),
    );
    expect(
      parseList({
        'items': [
          {'a': 1},
        ],
      }),
      hasLength(1),
    );
    expect(parseList(null), isEmpty);
  });

  test('channel links', () {
    expect(parseChannelLink('calltype://channel/ch-aaaa-bbbb'), 'CH-AAAA-BBBB');
    expect(parseChannelLink('calltype://contact/CT-AAAA-BBBB'), isNull);
    expect(parseChannelLink('ct://id/CT-AAAA-BBBB'), isNull);
    expect(parseChannelLink('calltype://channel/'), isNull);
  });
}
