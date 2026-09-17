import 'dart:convert';

/// Wire format of the Channels feature — EVERY JSON field name the client
/// reads or writes for channels lives in this one file.
///
/// WHY one file: the client was written against the plan text while the
/// server was built in parallel, so field names may need aligning during
/// integration. That must be a single-file edit, not a hunt through the UI.
///
/// WHY lenient parsing: a missing optional field (or a server that is one
/// version ahead/behind) must degrade to a default, never crash the feed.
/// Only the identifiers a row cannot exist without are required.

/// The six reactions the server accepts (anything else is a 422).
const channelReactionEmojis = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

/// Post kinds in v1 (plan §7.2 — no video).
const channelPostKinds = ['text', 'image', 'poll'];

/// Image attachment limit enforced by the server (413 above it); checked
/// client-side too so the user gets an immediate, clear message.
const channelImageMaxBytes = 2 * 1024 * 1024;

/// File extension → content type of the image types the server accepts
/// (anything else is a 415). SVG is deliberately absent on the server: it can
/// carry script and channel images are served unencrypted.
const channelImageTypes = {
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'webp': 'image/webp',
  'gif': 'image/gif',
};

/// Content type for an upload, or null when the server would refuse the file.
/// WHY by extension: the server whitelists on the multipart part's content
/// type, which the client has to state itself — bytes are never sniffed.
String? channelImageContentType(String fileName) {
  final dot = fileName.lastIndexOf('.');
  return dot < 0
      ? null
      : channelImageTypes[fileName.substring(dot + 1).toLowerCase()];
}

const channelLinkPrefix = 'calltype://channel/';

/// Extracts the channel handle from `calltype://channel/<handle>`, or null
/// when [raw] is not a channel link (e.g. a contact QR code).
String? parseChannelLink(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || uri.scheme != 'calltype' || uri.host != 'channel') {
    return null;
  }
  final handle = uri.pathSegments.isEmpty ? '' : uri.pathSegments.first;
  return handle.isEmpty ? null : handle.toUpperCase();
}

/// Public channel profile / one row of `GET /channels/mine`.
class ChannelInfo {
  const ChannelInfo({
    required this.channelId,
    required this.handle,
    required this.name,
    this.description = '',
    this.followerCount = 0,
    this.isFollowing = false,
    this.role,
    this.unreadCount = 0,
  });

  final String channelId;
  final String handle;
  final String name;
  final String description;
  final int followerCount;
  final bool isFollowing;

  /// 'owner' / 'admin' when the calling device may publish, else null.
  final String? role;
  final int unreadCount;

  bool get canPublish => role != null;

  factory ChannelInfo.fromJson(Map<String, dynamic> json) {
    // The server may express publishing rights as a role string or as a
    // plain isAdmin flag; accept both.
    final role = json['role'] as String?;
    return ChannelInfo(
      channelId: json['channelId'] as String,
      handle: json['handle'] as String? ?? '',
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      followerCount: _int(json['followerCount']) ?? 0,
      isFollowing: json['isFollowing'] as bool? ?? false,
      role: role ?? (json['isAdmin'] == true ? 'admin' : null),
      unreadCount: _int(json['unreadCount']) ?? 0,
    );
  }
}

/// A post from `GET /channels/{id}/posts` or the `ReceiveChannelPost` event.
class ChannelPostDto {
  const ChannelPostDto({
    required this.channelId,
    required this.postId,
    this.kind = 'text',
    this.body = '',
    this.attachmentBlobPath,
    required this.createdAt,
    this.deleted = false,
    this.reactions = const {},
    this.myReaction,
    this.pollVotes = const [],
    this.myVote,
  });

  final String channelId;
  final String postId;
  final String kind;
  final String body;
  final String? attachmentBlobPath;
  final DateTime createdAt;

  /// Tombstone: the post was deleted by an admin — remove it locally.
  final bool deleted;
  final Map<String, int> reactions;
  final String? myReaction;
  final List<int> pollVotes;
  final int? myVote;

  /// [channelId] is the fallback for list responses whose items do not
  /// repeat the channel id already present in the URL.
  factory ChannelPostDto.fromJson(
    Map<String, dynamic> json, {
    String? channelId,
  }) {
    final created = DateTime.tryParse(json['createdAt'] as String? ?? '');
    final reactions = json['reactions'];
    return ChannelPostDto(
      channelId: json['channelId'] as String? ?? channelId!,
      postId: json['postId'] as String,
      kind: json['kind'] as String? ?? 'text',
      body: json['body'] as String? ?? '',
      attachmentBlobPath: json['attachmentBlobPath'] as String?,
      // A tombstone may omit the timestamp; "now" is harmless there because
      // a deleted post is never stored.
      createdAt: (created ?? DateTime.now()).toUtc(),
      deleted: json['deleted'] as bool? ?? false,
      reactions: reactions is Map
          ? {
              for (final e in reactions.entries)
                e.key as String: _int(e.value) ?? 0,
            }
          : const {},
      myReaction: json['myReaction'] as String?,
      pollVotes: _votes(json['votes']),
      myVote: _int(json['myVote']),
    );
  }
}

/// Fresh totals of one post — the response of `PUT/DELETE …/reaction` and
/// `PUT …/vote`. Server truth that replaces the client's optimistic guess.
class ChannelPostTotals {
  const ChannelPostTotals({
    this.reactions = const {},
    this.myReaction,
    this.pollVotes = const [],
    this.myVote,
  });

  final Map<String, int> reactions;
  final String? myReaction;
  final List<int> pollVotes;
  final int? myVote;

  factory ChannelPostTotals.fromJson(Map<String, dynamic> json) {
    // Same field names as a post, so reuse its (lenient) parser.
    final post = ChannelPostDto.fromJson({
      ...json,
      'postId': '',
    }, channelId: '');
    return ChannelPostTotals(
      reactions: post.reactions,
      myReaction: post.myReaction,
      pollVotes: post.pollVotes,
      myVote: post.myVote,
    );
  }
}

/// One row of `GET /channels/{id}/admins` (owner only) — the single place
/// the channel API exposes a device id.
class ChannelAdminDto {
  const ChannelAdminDto({required this.deviceId, this.addedAt});
  final String deviceId;
  final DateTime? addedAt;

  factory ChannelAdminDto.fromJson(Map<String, dynamic> json) =>
      ChannelAdminDto(
        deviceId: json['deviceId'] as String,
        addedAt: DateTime.tryParse(json['addedAt'] as String? ?? '')?.toUtc(),
      );
}

/// Body of a `kind: poll` post — a JSON string inside the post's `body`.
class ChannelPoll {
  const ChannelPoll({
    required this.question,
    required this.options,
    this.closesAt,
  });

  final String question;
  final List<String> options;
  final DateTime? closesAt;

  bool get closed => closesAt != null && DateTime.now().isAfter(closesAt!);

  /// Null when [body] is not a valid poll — the feed then shows the raw
  /// text instead of crashing on a malformed public post.
  static ChannelPoll? tryParse(String body) {
    try {
      final json = jsonDecode(body);
      if (json is! Map) return null;
      final options = json['options'];
      if (options is! List || options.isEmpty) return null;
      return ChannelPoll(
        question: json['question'] as String? ?? '',
        options: [for (final o in options) '$o'],
        closesAt: DateTime.tryParse(json['closesAt'] as String? ?? ''),
      );
    } catch (_) {
      return null;
    }
  }

  String encode() => jsonEncode({
    'question': question,
    'options': options,
    if (closesAt != null) 'closesAt': closesAt!.toUtc().toIso8601String(),
  });
}

// -- Response envelopes ------------------------------------------------------

/// `POST /channels/{id}/attachments` → 201 `{blobPath, name}`; `blobPath` is
/// the canonical `channel-media/{channelId}/{name}` a post must reference.
String parseUploadedBlobPath(Map<String, dynamic> json) =>
    json['blobPath'] as String;

/// List endpoints return a bare JSON array; an `{items: [...]}` envelope is
/// tolerated so a later pagination wrapper does not break old clients.
List<Map<String, dynamic>> parseList(Object? data) {
  final list = data is Map ? data['items'] : data;
  if (list is! List) return const [];
  return [
    for (final item in list)
      if (item is Map) item.cast<String, dynamic>(),
  ];
}

/// Error bodies are `{error, code}`; role / non-follower 403s have NO body,
/// hence [data] may be anything. Returns the machine-readable `code`.
String? parseErrorCode(Object? data) =>
    data is Map ? data['code'] as String? : null;

/// `ChannelDeleted` hub event → channel id.
String? parseChannelDeleted(Map<String, dynamic> json) =>
    json['channelId'] as String?;

// -- Request bodies ----------------------------------------------------------

Map<String, dynamic> createChannelBody(String name, String description) => {
  'name': name,
  'description': description,
};

/// `PATCH /channels/{id}` — the server leaves a null/absent property
/// unchanged, so only what the user edited is sent.
Map<String, dynamic> updateChannelBody({String? name, String? description}) => {
  'name': ?name,
  'description': ?description,
};

Map<String, dynamic> createPostBody({
  required String postId,
  required String kind,
  required String body,
  String? attachmentBlobPath,
}) => {
  'postId': postId,
  'kind': kind,
  'body': body,
  'attachmentBlobPath': ?attachmentBlobPath,
};

Map<String, dynamic> reactionBody(String emoji) => {'emoji': emoji};

Map<String, dynamic> voteBody(int optionIndex) => {'optionIndex': optionIndex};

Map<String, dynamic> reportBody(String reason, {String? postId}) => {
  'postId': ?postId,
  'reason': reason,
};

/// Query of `GET /channels/{id}/posts`. Cursors are UTC ISO-8601 strings.
Map<String, dynamic> postsQuery({String? before, String? after, int? limit}) =>
    {'before': ?before, 'after': ?after, 'limit': ?limit};

/// The server sends poll totals as a sparse map keyed by option index
/// (`{"0": 3, "2": 1}` — JSON object keys are strings, options without votes
/// are absent). The client works with a dense list indexed by option.
List<int> _votes(Object? votes) {
  if (votes is! Map) return const [];
  final list = <int>[];
  for (final entry in votes.entries) {
    final index = int.tryParse('${entry.key}');
    // Upper bound = the server's max option count; a garbage key must not
    // make a public post allocate a huge list.
    if (index == null || index < 0 || index >= 10) continue;
    while (list.length <= index) {
      list.add(0);
    }
    list[index] = _int(entry.value) ?? 0;
  }
  return list;
}

/// JSON sometimes delivers whole numbers as doubles (JS clients, SignalR).
int? _int(Object? value) => value is num ? value.toInt() : null;
