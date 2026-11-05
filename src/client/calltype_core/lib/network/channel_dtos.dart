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

// -- Moderation (contract 2026-11-05-channel-moderation) ----------------------

/// Channel roles as the API spells them. `publisher` may only publish and
/// delete its OWN posts; it may not edit the channel or manage admins.
const channelRoleOwner = 'owner';
const channelRoleAdmin = 'admin';
const channelRolePublisher = 'publisher';

/// Rule ids of the channel rules, exactly as decisions cite them.
const channelRuleIds = [
  'K1',
  'K2',
  'K3',
  'K4',
  'K5',
  'K6',
  'K7',
  'K8',
  'K9',
  'K10',
];

/// Report categories the server accepts (anything else is 400
/// `invalid_category`). `illegal` additionally needs `goodFaith: true`.
const channelReportCategories = ['illegal', 'terms', 'spam'];

/// Public channel rules page, optionally at one rule's anchor.
///
/// WHY only cs / en: the rules are a legal text published in Czech (binding)
/// and English; every other app language links the English page rather
/// than a machine translation of a legal document.
String channelRulesUrl(String languageCode, {String? rule}) {
  final lang = languageCode == 'cs' ? 'cs' : 'en';
  final anchor = rule != null && channelRuleIds.contains(rule) ? '#$rule' : '';
  return 'https://jay.zcloud.cz/legal/channels-$lang.html$anchor';
}

/// Machine codes of the moderation feature in `{error, code}` bodies.
abstract final class ChannelErrorCodes {
  /// 403 on feed / post / follow / react / vote of a suspended channel.
  static const channelSuspended = 'channel_suspended';

  /// 429 when a bot device exceeded its daily post budget in one channel.
  static const botPostLimit = 'bot_post_limit';
  static const goodFaithRequired = 'good_faith_required';
  static const invalidContact = 'invalid_contact';
  static const invalidCategory = 'invalid_category';
  static const invalidRole = 'invalid_role';
}

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
    this.status = 'active',
    this.suspendedUntil,
  });

  final String channelId;
  final String handle;
  final String name;
  final String description;
  final int followerCount;
  final bool isFollowing;

  /// 'owner' / 'admin' / 'publisher' when the calling device may publish,
  /// else null.
  final String? role;
  final int unreadCount;

  /// 'active' | 'suspended'. Defaults to active so a server that predates
  /// moderation (no field) never shows a channel as suspended.
  final String status;
  final DateTime? suspendedUntil;

  bool get canPublish => role != null;

  /// Owner / admin: may edit the profile. A publisher may not.
  bool get canEdit => role == channelRoleOwner || role == channelRoleAdmin;

  /// The server's status is authoritative at fetch time, but a cached
  /// profile whose suspension date has passed is no longer suspended
  /// (the server computes `SuspendedUntil > now` the same way).
  bool get isSuspended =>
      status == 'suspended' &&
      (suspendedUntil == null || suspendedUntil!.isAfter(DateTime.now()));

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
      status: json['status'] as String? ?? 'active',
      suspendedUntil: _date(json['suspendedUntil']),
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
    this.byBot = false,
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

  /// Published by a bot device (server-side `IsBot`), labelled in the feed.
  final bool byBot;

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
      byBot: json['byBot'] as bool? ?? false,
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
  const ChannelAdminDto({
    required this.deviceId,
    this.addedAt,
    this.role = channelRoleAdmin,
    this.isBot = false,
    this.handle,
    this.displayName,
  });
  final String deviceId;
  final DateTime? addedAt;

  /// 'admin' | 'publisher'. Older servers only had admins, hence the default.
  final String role;
  final bool isBot;

  /// Public user handle (CT-XXXX-XXXX) so the owner can tell members apart
  /// even without a matching contact.
  final String? handle;
  final String? displayName;

  bool get isPublisher => role == channelRolePublisher;

  factory ChannelAdminDto.fromJson(Map<String, dynamic> json) =>
      ChannelAdminDto(
        deviceId: json['deviceId'] as String,
        addedAt: _date(json['addedAt']),
        role: json['role'] as String? ?? channelRoleAdmin,
        isBot: json['isBot'] as bool? ?? false,
        handle: json['handle'] as String?,
        displayName: json['displayName'] as String?,
      );
}

/// Statement of reasons (DSA Art. 17) from `GET /channels/{id}/moderation`,
/// shown to the channel's owner / admins / publishers.
class ModerationStatement {
  const ModerationStatement({
    required this.decisionId,
    required this.action,
    this.postId,
    this.ground,
    this.rule,
    this.legalGround,
    this.explanation = '',
    this.suspendedUntil,
    this.basedOnReports = false,
    required this.createdAt,
  });

  final int decisionId;

  /// remove_post | suspend_channel | terminate_channel | restore_channel
  /// (`dismiss` is never sent to the owner).
  final String action;
  final String? postId;

  /// 'terms' (then [rule] is K1..K10) or 'illegal' (then [legalGround]).
  final String? ground;
  final String? rule;
  final String? legalGround;
  final String explanation;
  final DateTime? suspendedUntil;
  final bool basedOnReports;
  final DateTime createdAt;

  factory ModerationStatement.fromJson(Map<String, dynamic> json) =>
      ModerationStatement(
        decisionId: _int(json['decisionId']) ?? 0,
        action: json['action'] as String? ?? '',
        postId: json['postId'] as String?,
        ground: json['ground'] as String?,
        rule: json['rule'] as String?,
        legalGround: json['legalGround'] as String?,
        explanation: json['explanation'] as String? ?? '',
        suspendedUntil: _date(json['suspendedUntil']),
        basedOnReports: json['basedOnReports'] as bool? ?? false,
        createdAt: _date(json['createdAt']) ?? DateTime.now().toUtc(),
      );
}

/// One row of `GET /channels/reports/mine`: a report this device filed and
/// what became of it (DSA Art. 16(5)).
class MyReport {
  const MyReport({
    required this.reportId,
    required this.channelId,
    this.channelName = '',
    this.channelHandle = '',
    this.postId,
    this.category = 'terms',
    required this.createdAt,
    this.status = 'open',
    this.resolvedAt,
  });

  final int reportId;
  final String channelId;
  final String channelName;
  final String channelHandle;
  final String? postId;
  final String category;
  final DateTime createdAt;

  /// open | dismissed | actioned.
  final String status;
  final DateTime? resolvedAt;

  factory MyReport.fromJson(Map<String, dynamic> json) => MyReport(
    reportId: _int(json['reportId']) ?? 0,
    channelId: json['channelId'] as String? ?? '',
    channelName: json['channelName'] as String? ?? '',
    channelHandle: json['channelHandle'] as String? ?? '',
    postId: json['postId'] as String?,
    category: json['category'] as String? ?? 'terms',
    createdAt: _date(json['createdAt']) ?? DateTime.now().toUtc(),
    status: json['status'] as String? ?? 'open',
    resolvedAt: _date(json['resolvedAt']),
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

Map<String, dynamic> reportBody(
  String reason, {
  String? postId,
  String category = 'terms',
  String? contactEmail,
  bool goodFaith = false,
}) => {
  'postId': ?postId,
  'reason': reason,
  'category': category,
  'contactEmail': ?contactEmail,
  'goodFaith': goodFaith,
};

/// `POST /channels/{id}/report` answers 200 `{reportId, createdAt}`; a server
/// that predates moderation answers 204 without a body, then 0 = "no number".
int parseReportReceipt(Object? data) =>
    data is Map ? _int(data['reportId']) ?? 0 : 0;

/// `PUT /channels/{id}/admins/{deviceId}` body.
Map<String, dynamic> channelAdminRoleBody(String role) => {'role': role};

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

DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

/// JSON sometimes delivers whole numbers as doubles (JS clients, SignalR).
int? _int(Object? value) => value is num ? value.toInt() : null;
