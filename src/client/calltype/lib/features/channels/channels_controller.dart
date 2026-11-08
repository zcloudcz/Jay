import 'dart:async';
import 'dart:convert';

import 'package:calltype_core/network/channel_dtos.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/storage/database.dart';
import '../../l10n/l10n.dart';

/// Thrown when a blocked channel is opened from a link / QR code. Blocking
/// is client-side only, so this check IS the block — it must not be skipped.
class ChannelBlockedException implements Exception {
  const ChannelBlockedException(this.handle);
  final String handle;
}

/// A publish rejected on the device before any upload. Carries the same
/// `code` the server would answer with, so [channelErrorMessage] words the
/// local and the server-side rejection identically.
class ChannelValidationException implements Exception {
  const ChannelValidationException(this.code);
  final String code;
  @override
  String toString() => 'ChannelValidationException($code)';
}

/// User-facing text for a failed channel call, from the server's
/// `{error, code}` body. Role / non-follower 403s carry no body, so anything
/// unknown falls back to a generic line. One place, so every channel screen
/// words the same failure the same way. Takes [l10n] from the calling widget
/// — read it BEFORE an await, a BuildContext may be gone afterwards.
String channelErrorMessage(AppLocalizations l10n, Object error) {
  if (error is ChannelBlockedException) return l10n.channelErrorBlocked;
  final response = error is DioException ? error.response : null;
  final code = error is ChannelValidationException
      ? error.code
      : parseErrorCode(response?.data);
  return switch (code) {
    'account_required' => l10n.channelErrorAccountRequired,
    'channel_limit_reached' => l10n.channelErrorLimitReached,
    'poll_closed' => l10n.channelErrorPollClosed,
    'emoji_not_allowed' => l10n.channelErrorEmojiNotAllowed,
    'invalid_option_index' || 'not_a_poll' => l10n.channelErrorInvalidPollOption,
    'report_limit_reached' => l10n.channelErrorReportLimit,
    'image_too_large' => l10n.channelErrorImageTooLarge,
    'unsupported_image_type' => l10n.channelErrorImageType,
    'post_id_conflict' => l10n.channelErrorPostConflict,
    ChannelErrorCodes.channelSuspended => l10n.channelErrorSuspended,
    ChannelErrorCodes.botPostLimit => l10n.channelErrorBotPostLimit,
    ChannelErrorCodes.goodFaithRequired => l10n.channelErrorGoodFaithRequired,
    ChannelErrorCodes.invalidContact => l10n.channelReportEmailInvalid,
    _ =>
      response?.statusCode == 403
          ? l10n.channelErrorForbidden
          : l10n.channelErrorGeneric,
  };
}

/// A device found by its user handle, to be appointed admin / publisher.
class ChannelMemberCandidate {
  const ChannelMemberCandidate({
    required this.deviceId,
    required this.handle,
    this.displayName,
    this.isBot = false,
  });
  final String deviceId;
  final String handle;
  final String? displayName;
  final bool isBot;

  String get name => displayName ?? handle;
}

/// Suspension as the UI needs it, from the cached channel row: still in
/// force (a stored end date in the past no longer counts) and its end date.
bool channelIsSuspended(Channel channel) =>
    channel.status == 'suspended' &&
    (channel.suspendedUntil == null ||
        channel.suspendedUntil!.isAfter(DateTime.now()));

/// App-wide state of public channels: followed/administered channels, the
/// local post cache, unread counts, blocking.
///
/// Channels are deliberately kept apart from chats: posts are PUBLIC
/// plaintext (not end-to-end encrypted), so this controller only ever
/// touches the `channels`, `channel_posts` and `blocked_channels` tables —
/// never `messages` or `conversations`.
///
/// App-wide (started in main.dart, like the message inbox) rather than
/// route-scoped, because hub events must be stored and counted as unread
/// even while no channel screen is open.
///
/// The hub is injected as plain streams/callbacks (same style as
/// MessageInboxService) so tests can drive it without a SignalR connection.
class ChannelsController extends ChangeNotifier {
  ChannelsController({
    required AppDatabase database,
    required ApiClient apiClient,
    required Stream<Map<String, dynamic>> channelPosts,
    required Stream<Map<String, dynamic>> channelDeleted,
    required Future<void> Function() joinChannels,
    required Future<void> Function(String channelId) leaveChannel,
  }) : _db = database,
       _api = apiClient,
       _joinChannels = joinChannels,
       _leaveChannel = leaveChannel {
    _subscriptions = [
      channelPosts.listen(_enqueue(_onPostEvent)),
      channelDeleted.listen(_enqueue(_onChannelDeleted)),
    ];
  }

  final AppDatabase _db;
  final ApiClient _api;
  final Future<void> Function() _joinChannels;
  final Future<void> Function(String channelId) _leaveChannel;
  late final List<StreamSubscription<Map<String, dynamic>>> _subscriptions;
  bool _disposed = false;
  static const _uuid = Uuid();

  /// Posts fetched per page / on opening a feed.
  static const pageSize = 50;

  List<Channel> get channels => List.unmodifiable(_channels);
  List<Channel> _channels = [];

  List<BlockedChannel> get blocked => List.unmodifiable(_blocked);
  List<BlockedChannel> _blocked = [];

  /// Badge on the Updates tab.
  int get totalUnread => _channels.fold(0, (sum, c) => sum + c.unreadCount);

  /// Posts that are NEW to this device, for local notifications: every new
  /// live post, and the newest one of a catch-up after a reconnect (never
  /// the history fetched for an empty feed). Own posts are stored before the
  /// hub echoes them, so they never show up here.
  Stream<ChannelPostDto> get newPosts => _arrivals.stream;
  final _arrivals = StreamController<ChannelPostDto>.broadcast();

  /// The feed currently on screen: its new posts are read immediately and
  /// must not bump the unread badge.
  String? _openChannelId;

  // Hub events are handled strictly one after another. Two copies of the
  // same post arriving back-to-back (reconnect replay) would otherwise both
  // pass the "already stored?" check before either insert lands, and the
  // unread badge would count the post twice.
  Future<void> _queue = Future.value();
  void Function(Map<String, dynamic>) _enqueue(
    Future<void> Function(Map<String, dynamic>) handler,
  ) => (event) {
    _queue = _queue.then((_) => handler(event)).catchError((Object _) {});
  };

  /// Completes when every hub event received so far has been processed.
  @visibleForTesting
  Future<void> get idle => _queue;

  /// Loads local state. Call once at startup, before [sync].
  Future<void> load() async {
    _channels = await (_db.select(
      _db.channels,
    )..orderBy([(c) => OrderingTerm(expression: c.name)])).get();
    _blocked = await _db.select(_db.blockedChannels).get();
    if (!_disposed) notifyListeners();
  }

  bool isBlocked({String? channelId, String? handle}) => _blocked.any(
    (b) =>
        b.channelId == channelId ||
        (handle != null && b.handle.toUpperCase() == handle.toUpperCase()),
  );

  Channel? channel(String channelId) {
    for (final c in _channels) {
      if (c.channelId == channelId) return c;
    }
    return null;
  }

  // -- Offline sync ----------------------------------------------------------

  /// Catch-up after app start / reconnect.
  ///
  /// The server keeps NO per-follower queue for channels (a channel with
  /// 10 000 followers would explode it), so the client pulls: one
  /// `GET /channels/mine`, then posts only for channels that report unread
  /// items. There is deliberately no per-channel polling loop — live posts
  /// arrive over the hub once [_joinChannels] has subscribed the connection.
  Future<void> sync() async {
    final mine = await _api.getMyChannels();
    final keep = <String>{};
    for (final info in mine) {
      if (isBlocked(channelId: info.channelId)) continue;
      keep.add(info.channelId);
      final local = channel(info.channelId);
      // A follower of a suspended channel gets 403 channel_suspended on the
      // feed; one such channel must not abort the sync of all the others.
      final added = info.unreadCount > 0 && !_feedBlocked(info)
          ? await _catchUp(info.channelId)
          : 0;
      // WHY not simply the server's unreadCount: fetching posts is what the
      // server counts as "seen", so after one catch-up it reports 0 although
      // the user never opened the feed — the next sync would wipe the badge.
      // For a known channel the badge is therefore kept locally: what was
      // unread stays unread, plus what this catch-up brought.
      final unread = info.channelId == _openChannelId
          ? 0
          : local == null
          ? info.unreadCount
          : local.unreadCount + added;
      // A listed channel without a publishing role can only be listed
      // because this device follows it, even if the flag was omitted.
      await _upsertChannel(
        info,
        isFollowing: info.isFollowing || info.role == null,
        unreadCount: unread,
      );
    }
    // Unfollowed on another device of the account, or deleted while offline.
    for (final local in List.of(_channels)) {
      if (!keep.contains(local.channelId)) await _forget(local.channelId);
    }
    await load();
    // Group membership lives on the connection → renew after every connect.
    try {
      await _joinChannels();
    } catch (_) {
      // Offline again already; the next reconnect calls sync() anew.
    }
  }

  /// Pulls everything newer than the newest cached post; returns how many
  /// posts were new.
  ///
  /// `?after=` returns the OLDEST [pageSize] posts after the cursor (newest
  /// first inside the page), so a client that missed several pages walks
  /// FORWARD: the newest createdAt of a page is the next cursor, until a page
  /// comes back short.
  Future<int> _catchUp(String channelId) async {
    var cursor = await _newestCursor(channelId);
    // An empty cache means a first fetch (new follow, fresh install): those
    // posts are history, not news, so they never raise a notification.
    final announce = cursor != null;
    var added = 0;
    final fresh = <ChannelPostDto>[];
    void announceNewest() {
      if (!announce || fresh.isEmpty || _arrivals.isClosed) return;
      // One notification per channel and catch-up, for the newest post: the
      // notifications of a channel replace each other anyway (spec N4).
      fresh.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      _arrivals.add(fresh.last);
    }

    while (true) {
      final page = await _api.getChannelPosts(
        channelId,
        after: cursor,
        limit: pageSize,
      );
      added += await _storePosts(page, newPosts: fresh);
      // No cursor = empty cache: the server answered with the newest page,
      // which is all a fresh feed needs (history loads on demand).
      if (cursor == null || page.length < pageSize) {
        announceNewest();
        return added;
      }
      // Tombstones are not stored, so the cursor comes from the page itself.
      final next = page.first.createdAt.toUtc().toIso8601String();
      // A cursor that does not advance would loop forever. It can happen on
      // web, where DateTime has millisecond precision: a full page of posts
      // within one millisecond truncates back to the same cursor.
      if (cursor.compareTo(next) >= 0) {
        announceNewest();
        return added;
      }
      cursor = next;
    }
  }

  /// True when the server would refuse the feed: suspended channel and this
  /// device has no role in it (owner / admin / publisher still read it).
  bool _feedBlocked(ChannelInfo info) => info.isSuspended && info.role == null;

  Future<String?> _newestCursor(String channelId) async {
    final newest =
        await (_db.select(_db.channelPosts)
              ..where((p) => p.channelId.equals(channelId))
              ..orderBy([(p) => OrderingTerm.desc(p.createdAt)])
              ..limit(1))
            .getSingleOrNull();
    return newest?.createdAt;
  }

  // -- Discovery / follow ----------------------------------------------------

  /// Resolves a channel from a link, QR code or typed handle. Refuses
  /// blocked channels: a block that a link could bypass would be no block.
  Future<ChannelInfo> openByHandle(String handle) async {
    if (isBlocked(handle: handle)) throw ChannelBlockedException(handle);
    final info = await _api.getChannel(handle);
    if (isBlocked(channelId: info.channelId)) {
      throw ChannelBlockedException(handle);
    }
    return info;
  }

  /// Following is always an explicit user action — nothing follows a
  /// channel automatically.
  Future<void> follow(ChannelInfo info) async {
    if (isBlocked(channelId: info.channelId)) {
      throw ChannelBlockedException(info.handle);
    }
    await _api.followChannel(info.channelId);
    await _upsertChannel(info, isFollowing: true);
    await load();
    try {
      await _joinChannels();
    } catch (_) {}
    await refresh(info.channelId);
  }

  Future<void> unfollow(String channelId) async {
    await _api.unfollowChannel(channelId);
    await _stopLocally(channelId);
  }

  /// Local part of unfollow. An owner/admin keeps the channel listed (they
  /// still have to manage it); a plain follower's copy is removed.
  Future<void> _stopLocally(String channelId) async {
    if (channel(channelId)?.role == null) {
      try {
        await _leaveChannel(channelId);
      } catch (_) {}
      await _forget(channelId);
    } else {
      await (_db.update(_db.channels)
            ..where((c) => c.channelId.equals(channelId)))
          .write(const ChannelsCompanion(isFollowing: Value(false)));
    }
    await load();
  }

  // -- Block (client-side only, plan §7.5) -----------------------------------

  /// Unfollow + remember locally. The server is never told about the block.
  /// Unfollow is best effort: blocking must also work offline, and
  /// [_onPostEvent] drops posts of blocked channels regardless.
  Future<void> block({
    required String channelId,
    required String handle,
    required String name,
  }) async {
    await _db
        .into(_db.blockedChannels)
        .insertOnConflictUpdate(
          BlockedChannelsCompanion.insert(
            channelId: channelId,
            handle: handle,
            name: name,
            blockedAt: DateTime.now(),
          ),
        );
    try {
      await _api.unfollowChannel(channelId);
    } catch (_) {}
    try {
      await _leaveChannel(channelId);
    } catch (_) {}
    await _forget(channelId);
    await load();
  }

  Future<void> unblock(String channelId) async {
    await (_db.delete(
      _db.blockedChannels,
    )..where((b) => b.channelId.equals(channelId))).go();
    await load();
  }

  /// Files a report and returns the server's report number (0 from a
  /// server without receipts).
  Future<int> report(
    String channelId, {
    String? postId,
    required String reason,
    String category = 'terms',
    String? contactEmail,
    bool goodFaith = false,
  }) => _api.reportChannel(
    channelId,
    postId: postId,
    reason: reason,
    category: category,
    contactEmail: contactEmail,
    goodFaith: goodFaith,
  );

  /// Reports this device filed, with their outcome ("Reports I filed").
  Future<List<MyReport>> myReports() => _api.getMyReports();

  /// Statements of reasons for the channel (owner / admin / publisher).
  Future<List<ModerationStatement>> moderation(String channelId) =>
      _api.getChannelModeration(channelId);

  // -- Feed ------------------------------------------------------------------

  /// Oldest first — the feed shows the newest post at the bottom.
  Stream<List<ChannelPost>> watchPosts(String channelId) =>
      (_db.select(_db.channelPosts)
            ..where((p) => p.channelId.equals(channelId))
            ..orderBy([(p) => OrderingTerm.asc(p.createdAt)]))
          .watch();

  /// Marks the feed as on screen and read. Pass null when leaving it.
  Future<void> setOpenChannel(String? channelId) async {
    _openChannelId = channelId;
    if (channelId == null) return;
    await (_db.update(_db.channels)
          ..where((c) => c.channelId.equals(channelId)))
        .write(const ChannelsCompanion(unreadCount: Value(0)));
    await load();
  }

  /// One fetch of the newest page when a feed is opened: refreshes reaction
  /// and vote totals, which are not pushed over the hub.
  ///
  /// A 403 `channel_suspended` is not an error for the user but a state: it
  /// is stored on the channel so the feed shows the suspension instead of a
  /// stale cache (the next sync clears it once the channel is active again).
  Future<void> refresh(String channelId) async {
    final List<ChannelPostDto> page;
    try {
      page = await _api.getChannelPosts(channelId, limit: pageSize);
    } on DioException catch (error) {
      if (parseErrorCode(error.response?.data) !=
          ChannelErrorCodes.channelSuspended) {
        rethrow;
      }
      await (_db.update(_db.channels)
            ..where((c) => c.channelId.equals(channelId)))
          .write(const ChannelsCompanion(status: Value('suspended')));
      await load();
      return;
    }
    await _storePosts(page, overwrite: true);
  }

  /// Loads one page of history above the oldest cached post.
  /// Returns false when there is nothing older.
  Future<bool> loadOlder(String channelId) async {
    final oldest =
        await (_db.select(_db.channelPosts)
              ..where((p) => p.channelId.equals(channelId))
              ..orderBy([(p) => OrderingTerm.asc(p.createdAt)])
              ..limit(1))
            .getSingleOrNull();
    final page = await _api.getChannelPosts(
      channelId,
      before: oldest?.createdAt,
      limit: pageSize,
    );
    await _storePosts(page, overwrite: true);
    return page.length >= pageSize;
  }

  // -- Publishing (owner / admin) ---------------------------------------------

  /// Publishes a post. For an image, [imageBytes] is uploaded first.
  ///
  /// The post id is generated HERE so a retry after a lost response cannot
  /// publish twice (the server treats a repeated id as a no-op) and so the
  /// hub echo of our own post is recognised as a duplicate.
  Future<void> publish(
    String channelId, {
    required String kind,
    required String body,
    Uint8List? imageBytes,
    String? imageName,
  }) async {
    String? blobPath;
    if (imageBytes != null) {
      // Checked here as well as on the server (413 / 415) so the user gets
      // a clear message before a pointless upload.
      if (channelImageContentType(imageName ?? '') == null) {
        throw const ChannelValidationException('unsupported_image_type');
      }
      if (imageBytes.length > channelImageMaxBytes) {
        throw const ChannelValidationException('image_too_large');
      }
      blobPath = await _api.uploadChannelAttachment(
        channelId,
        imageBytes,
        imageName!,
      );
    }
    final postId = _uuid.v4();
    // Store what the SERVER stored, not what was sent: its createdAt is the
    // paging cursor (a local clock would shift it) and a poll body comes back
    // normalised. overwrite: the hub echo may have landed first.
    await _storePosts(
      [
        await _api.createChannelPost(
          channelId,
          postId: postId,
          kind: kind,
          body: body,
          attachmentBlobPath: blobPath,
        ),
      ],
      overwrite: true,
      publishedHere: true,
    );
  }

  /// Admin delete (a publisher: own posts only, the server enforces it).
  /// Followers receive a tombstone event; locally the row is
  /// simply removed.
  Future<void> deletePost(String channelId, String postId) async {
    await _api.deleteChannelPost(channelId, postId);
    await _deletePost(postId);
  }

  Future<Uint8List> loadAttachment(String channelId, String blobPath) async =>
      Uint8List.fromList(await _api.getChannelAttachment(channelId, blobPath));

  // -- Reactions / polls -----------------------------------------------------

  /// Sets, changes or (same emoji again) removes this device's reaction.
  ///
  /// The response carries the post's real totals, which also include what
  /// OTHER followers did meanwhile — so they are stored as they are instead
  /// of being guessed from the cached numbers.
  Future<void> react(ChannelPost post, String emoji) async => _applyTotals(
    post.postId,
    await _api.setChannelReaction(
      post.channelId,
      post.postId,
      post.myReaction == emoji ? null : emoji,
    ),
  );

  Future<void> vote(ChannelPost post, int optionIndex) async => _applyTotals(
    post.postId,
    await _api.voteChannelPoll(post.channelId, post.postId, optionIndex),
  );

  // ponytail: no optimistic update — the chip changes after the round trip.
  // Add one (then reconcile here) if the delay is noticeable on slow links.
  Future<void> _applyTotals(String postId, ChannelPostTotals totals) =>
      (_db.update(
        _db.channelPosts,
      )..where((p) => p.postId.equals(postId))).write(
        ChannelPostsCompanion(
          reactions: Value(jsonEncode(totals.reactions)),
          myReaction: Value(totals.myReaction),
          pollVotes: Value(jsonEncode(totals.pollVotes)),
          myVote: Value(totals.myVote),
        ),
      );

  // -- Create / admins -------------------------------------------------------

  /// Creates a channel. The server answers 403 unless this device is linked
  /// to a registered account; the create screen explains that up front.
  Future<Channel> createChannel(String name, String description) async {
    // The response is the full profile (trimmed name, handle, role: owner).
    final created = await _api.createChannel(name, description);
    await _upsertChannel(created);
    await load();
    try {
      await _joinChannels();
    } catch (_) {}
    return channel(created.channelId)!;
  }

  /// Owner/admin: edit the profile. Null = leave unchanged.
  Future<void> updateChannel(
    String channelId, {
    String? name,
    String? description,
  }) async {
    final info = await _api.updateChannel(
      channelId,
      name: name,
      description: description,
    );
    // The PATCH response has no unread count — keep the local badge.
    await _upsertChannel(info, unreadCount: channel(channelId)?.unreadCount);
    await load();
  }

  /// Owner: delete the channel for everybody. Followers learn about it via
  /// `ChannelDeleted`; this device cleans up right away.
  Future<void> deleteChannel(String channelId) async {
    await _api.deleteChannel(channelId);
    try {
      await _leaveChannel(channelId);
    } catch (_) {}
    await _forget(channelId);
    await load();
  }

  Future<List<ChannelAdminDto>> admins(String channelId) =>
      _api.getChannelAdmins(channelId);

  /// Appoints (or with [admin] false removes) a member; [role] is
  /// 'admin' or 'publisher'. Calling it for an existing member changes
  /// its role.
  Future<void> setAdmin(
    String channelId,
    String deviceId,
    bool admin, {
    String role = channelRoleAdmin,
  }) => _api.setChannelAdmin(channelId, deviceId, admin: admin, role: role);

  /// Resolves a user handle to a device for "add by handle": a publisher
  /// (typically a bot) need not be in the owner's contacts. Null when no
  /// device has the handle (404).
  Future<ChannelMemberCandidate?> lookupHandle(String handle) async {
    try {
      final json = await _api.findDeviceByHandle(handle.trim().toUpperCase());
      final deviceId = json['deviceId'] as String?;
      if (deviceId == null) return null;
      return ChannelMemberCandidate(
        deviceId: deviceId,
        handle: json['userHandle'] as String? ?? handle.trim().toUpperCase(),
        displayName: json['displayName'] as String?,
        isBot: json['isBot'] as bool? ?? false,
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  // -- Hub events ------------------------------------------------------------

  Future<void> _onPostEvent(Map<String, dynamic> event) async {
    final post = ChannelPostDto.fromJson(event);
    // Blocked or not (any longer) followed: drop. The server may still
    // deliver for a moment after unfollow/block until LeaveChannel lands.
    if (isBlocked(channelId: post.channelId) ||
        channel(post.channelId) == null) {
      return;
    }
    if (post.deleted) {
      await _deletePost(post.postId);
      return;
    }
    final isNew = await _storePosts([post]);
    if (isNew > 0 && !_arrivals.isClosed) _arrivals.add(post);
    if (isNew > 0 && post.channelId != _openChannelId) {
      await _db.customUpdate(
        'UPDATE channels SET unread_count = unread_count + 1 '
        'WHERE channel_id = ?',
        variables: [Variable.withString(post.channelId)],
        updates: {_db.channels},
      );
      await load();
    }
  }

  Future<void> _onChannelDeleted(Map<String, dynamic> event) async {
    final channelId = parseChannelDeleted(event);
    if (channelId == null) return;
    await _forget(channelId);
    await load();
  }

  // -- Storage helpers -------------------------------------------------------

  /// Stores posts and returns how many were NEW. Tombstones delete.
  /// Without [overwrite] an existing row is left untouched (a bare hub event
  /// must not wipe cached reaction totals); with it, server truth wins.
  ///
  /// [publishedHere] marks this device's own posts. It is only ever WRITTEN
  /// as true; otherwise the column is left absent so a later overwrite with
  /// server data (which knows no author) keeps the mark.
  Future<int> _storePosts(
    List<ChannelPostDto> posts, {
    bool overwrite = false,
    bool publishedHere = false,
    List<ChannelPostDto>? newPosts,
  }) async {
    var added = 0;
    for (final post in posts) {
      if (post.deleted) {
        await _deletePost(post.postId);
        continue;
      }
      final exists =
          await (_db.select(
            _db.channelPosts,
          )..where((p) => p.postId.equals(post.postId))).getSingleOrNull() !=
          null;
      if (exists && !overwrite) continue;
      await _db
          .into(_db.channelPosts)
          .insertOnConflictUpdate(
            ChannelPostsCompanion.insert(
              postId: post.postId,
              channelId: post.channelId,
              kind: post.kind,
              body: Value(post.body),
              attachmentBlobPath: Value(post.attachmentBlobPath),
              createdAt: post.createdAt.toUtc().toIso8601String(),
              reactions: Value(jsonEncode(post.reactions)),
              myReaction: Value(post.myReaction),
              pollVotes: Value(jsonEncode(post.pollVotes)),
              myVote: Value(post.myVote),
              byBot: Value(post.byBot),
              publishedHere: publishedHere
                  ? const Value(true)
                  : const Value.absent(),
            ),
          );
      if (!exists) {
        added++;
        newPosts?.add(post);
      }
    }
    return added;
  }

  Future<void> _deletePost(String postId) => (_db.delete(
    _db.channelPosts,
  )..where((p) => p.postId.equals(postId))).go();

  Future<void> _upsertChannel(
    ChannelInfo info, {
    bool? isFollowing,
    int? unreadCount,
  }) => _db
      .into(_db.channels)
      .insertOnConflictUpdate(
        ChannelsCompanion.insert(
          channelId: info.channelId,
          handle: info.handle,
          name: info.name,
          description: Value(info.description),
          followerCount: Value(info.followerCount),
          role: Value(info.role),
          isFollowing: Value(isFollowing ?? info.isFollowing),
          unreadCount: Value(unreadCount ?? info.unreadCount),
          status: Value(info.isSuspended ? 'suspended' : 'active'),
          suspendedUntil: Value(info.isSuspended ? info.suspendedUntil : null),
        ),
      );

  Future<void> _forget(String channelId) async {
    await (_db.delete(
      _db.channelPosts,
    )..where((p) => p.channelId.equals(channelId))).go();
    await (_db.delete(
      _db.channels,
    )..where((c) => c.channelId.equals(channelId))).go();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _arrivals.close();
    super.dispose();
  }
}
