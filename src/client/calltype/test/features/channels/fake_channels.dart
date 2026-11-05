import 'dart:async';

import 'package:calltype/core/network/api_client.dart';
import 'package:calltype/core/storage/database.dart';
import 'package:calltype/features/channels/channels_controller.dart';
import 'package:calltype_core/network/channel_dtos.dart';
import 'package:dio/dio.dart';
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

  /// What the reaction / vote endpoints answer (server truth).
  ChannelPostTotals totals = const ChannelPostTotals();

  /// createdAt the "server" stamps on a published post.
  DateTime serverNow = DateTime.utc(2026, 9, 17, 12);
  List<ChannelAdminDto> admins = [];

  /// Simulates a broken cursor: every catch-up page is the same full page.
  bool stuck = false;

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
    if (suspendedFeeds.contains(channelId)) {
      final options = RequestOptions(path: '/channels/$channelId/posts');
      throw DioException(
        requestOptions: options,
        response: Response(
          requestOptions: options,
          statusCode: 403,
          data: {'error': 'suspended', 'code': 'channel_suspended'},
        ),
      );
    }
    // Same semantics as the server: `after` alone → the OLDEST `limit` posts
    // after the cursor; otherwise the newest `limit`. Always newest first.
    final all = [...?posts[channelId]]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final take = limit ?? 50;
    if (after != null && before == null) {
      final cursor = DateTime.parse(after);
      final newer = stuck
          ? all
          : all.where((p) => p.createdAt.isAfter(cursor)).toList();
      return newer.take(take).toList().reversed.toList();
    }
    return all.reversed.take(take).toList();
  }

  @override
  Future<ChannelInfo> createChannel(String name, String description) async {
    calls.add('create $name');
    return ChannelInfo(
      channelId: 'new',
      handle: 'CH-NEW0-0001',
      name: name,
      description: description,
      role: 'owner',
    );
  }

  @override
  Future<ChannelInfo> updateChannel(
    String channelId, {
    String? name,
    String? description,
  }) async {
    calls.add('patch $channelId name=$name description=$description');
    return ChannelInfo(
      channelId: channelId,
      handle: 'CH-NEWS-0001',
      name: name ?? 'News',
      description: description ?? '',
      role: 'owner',
    );
  }

  @override
  Future<void> deleteChannel(String channelId) async =>
      calls.add('delete $channelId');

  @override
  Future<List<ChannelAdminDto>> getChannelAdmins(String channelId) async =>
      admins;

  @override
  Future<void> setChannelAdmin(
    String channelId,
    String deviceId, {
    required bool admin,
    String role = 'admin',
  }) async {
    calls.add(admin ? 'admin $deviceId $admin $role' : 'admin $deviceId false');
    admins = [
      for (final a in admins)
        if (a.deviceId != deviceId) a,
      if (admin) ChannelAdminDto(deviceId: deviceId, role: role),
    ];
  }

  /// Answer of `POST /channels/{id}/report` (the receipt number).
  int reportId = 41;
  Map<String, Object?>? lastReport;

  @override
  Future<int> reportChannel(
    String channelId, {
    String? postId,
    required String reason,
    String category = 'terms',
    String? contactEmail,
    bool goodFaith = false,
  }) async {
    calls.add('report $channelId');
    lastReport = {
      'postId': postId,
      'reason': reason,
      'category': category,
      'contactEmail': contactEmail,
      'goodFaith': goodFaith,
    };
    return reportId;
  }

  List<MyReport> myReports = [];

  @override
  Future<List<MyReport>> getMyReports() async {
    calls.add('reports mine');
    return myReports;
  }

  List<ModerationStatement> statements = [];
  bool failModeration = false;

  @override
  Future<List<ModerationStatement>> getChannelModeration(
    String channelId,
  ) async {
    calls.add('moderation $channelId');
    if (failModeration) throw StateError('403');
    return statements;
  }

  /// Devices findable by handle (`GET /devices/by-handle/{handle}`).
  final devicesByHandle = <String, Map<String, dynamic>>{};

  @override
  Future<Map<String, dynamic>> findDeviceByHandle(String handle) async {
    calls.add('by-handle $handle');
    final device = devicesByHandle[handle];
    if (device == null) {
      final options = RequestOptions(path: '/devices/by-handle/$handle');
      throw DioException(
        requestOptions: options,
        response: Response(requestOptions: options, statusCode: 404),
      );
    }
    return device;
  }

  /// Simulates a suspended channel for followers (403 channel_suspended).
  final suspendedFeeds = <String>{};

  @override
  Future<ChannelPostDto> createChannelPost(
    String channelId, {
    required String postId,
    required String kind,
    required String body,
    String? attachmentBlobPath,
  }) async {
    calls.add('post $channelId $kind');
    return ChannelPostDto(
      channelId: channelId,
      postId: postId,
      kind: kind,
      body: body,
      attachmentBlobPath: attachmentBlobPath,
      createdAt: serverNow,
    );
  }

  @override
  Future<ChannelPostTotals> setChannelReaction(
    String channelId,
    String postId,
    String? emoji,
  ) async {
    calls.add('react $postId $emoji');
    return totals;
  }

  @override
  Future<ChannelPostTotals> voteChannelPoll(
    String channelId,
    String postId,
    int optionIndex,
  ) async {
    calls.add('vote $postId $optionIndex');
    return totals;
  }
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
  bool byBot = false,
  String createdAt = '2026-09-17T10:00:00.000Z',
}) => {
  'byBot': byBot,
  'channelId': channelId,
  'postId': postId,
  'kind': 'text',
  'body': 'hello $postId',
  'attachmentBlobPath': null,
  'createdAt': createdAt,
  'deleted': deleted,
};
