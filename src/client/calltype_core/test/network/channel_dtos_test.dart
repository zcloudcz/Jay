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
        'pollVotes': [3, 1],
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
