import 'dart:async';

import 'package:calltype/core/network/api_client.dart';
import 'package:calltype/core/storage/database.dart';
import 'package:calltype/features/channels/channels_controller.dart';
import 'package:calltype_core/network/channel_dtos.dart';
import 'package:drift/native.dart';

/// In-memory stand-in for the channel endpoints (same subclassing style as
/// the other feature tests). Records calls so tests can assert on traffic.
class FakeChannelApi extends ApiClient {
  FakeChannelApi() : super(baseUrl: 'http://unused');

  final profiles = <String, ChannelInfo>{}; // by handle
  List<ChannelInfo> mine = [];
  final posts = <String, List<ChannelPostDto>>{}; // by channel id
  final calls = <String>[];
  bool failUnfollow = false;

  @override
  Future<ChannelInfo> getChannel(String idOrHandle) async {
    calls.add('get $idOrHandle');
    return profiles[idOrHandle]!;
  }

  @override
  Future<List<ChannelInfo>> getMyChannels() async {
    calls.add('mine');
    return mine;
  }

  @override
  Future<void> followChannel(String channelId) async =>
      calls.add('follow $channelId');

  @override
  Future<void> unfollowChannel(String channelId) async {
    calls.add('unfollow $channelId');
    if (failUnfollow) throw StateError('offline');
  }

  @override
  Future<List<ChannelPostDto>> getChannelPosts(
    String channelId, {
    String? before,
    String? after,
    int? limit,
  }) async {
    calls.add('posts $channelId after=$after');
    return posts[channelId] ?? const [];
  }

  @override
  Future<void> createChannelPost(
    String channelId, {
    required String postId,
    required String kind,
    required String body,
    String? attachmentBlobPath,
  }) async => calls.add('post $channelId $kind');

  @override
  Future<void> setChannelReaction(
    String channelId,
    String postId,
    String? emoji,
  ) async => calls.add('react $postId $emoji');

  @override
  Future<void> voteChannelPoll(
    String channelId,
    String postId,
    int optionIndex,
  ) async => calls.add('vote $postId $optionIndex');
}

/// Controller wired to a fake API, an in-memory DB and hand-driven hub
/// streams.
class ChannelHarness {
  ChannelHarness() {
    controller = ChannelsController(
      database: db,
      apiClient: api,
      channelPosts: postEvents.stream,
      channelDeleted: deletedEvents.stream,
      joinChannels: () async => hubCalls.add('JoinChannels'),
      leaveChannel: (id) async => hubCalls.add('LeaveChannel $id'),
    );
  }

  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final api = FakeChannelApi();
  final postEvents = StreamController<Map<String, dynamic>>.broadcast();
  final deletedEvents = StreamController<Map<String, dynamic>>.broadcast();
  final hubCalls = <String>[];
  late final ChannelsController controller;

  /// Delivers a hub event and waits until the controller has processed it.
  Future<void> emitPost(Map<String, dynamic> event) async {
    postEvents.add(event);
    await Future<void>.delayed(Duration.zero);
    await controller.idle;
  }

  Future<void> dispose() async {
    controller.dispose();
    await postEvents.close();
    await deletedEvents.close();
    await db.close();
  }
}

const news = ChannelInfo(
  channelId: 'c1',
  handle: 'CH-NEWS-0001',
  name: 'News',
  followerCount: 7,
);

Map<String, dynamic> postEvent(
  String postId, {
  String channelId = 'c1',
  bool deleted = false,
  String createdAt = '2026-09-17T10:00:00.000Z',
}) => {
  'channelId': channelId,
  'postId': postId,
  'kind': 'text',
  'body': 'hello $postId',
  'attachmentBlobPath': null,
  'createdAt': createdAt,
  'deleted': deleted,
};
