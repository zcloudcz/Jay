/// DTOs of the operator API, contract section 4
/// (`docs/superpowers/specs/2026-11-05-channel-moderation-contract.md`).
///
/// Parsing is lenient on purpose (missing optional fields become null /
/// defaults): the server is built in parallel and a missing cosmetic field
/// must not blank the whole moderation queue.
library;

DateTime? _ts(Object? v) =>
    v is String && v.isNotEmpty ? DateTime.tryParse(v)?.toUtc() : null;

DateTime _tsReq(Object? v) =>
    _ts(v) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

int _int(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

String _str(Object? v) => v is String ? v : (v == null ? '' : '$v');

String? _strOrNull(Object? v) => v is String ? v : null;

class Rules {
  Rules._();

  /// Exactly the 10 rule ids of the contract (section 1).
  static const ids = ['K1', 'K2', 'K3', 'K4', 'K5', 'K6', 'K7', 'K8', 'K9', 'K10'];

  /// Public rules page anchor; cs operators get the binding Czech text.
  static Uri url(String rule, String languageCode) => Uri.parse(
    'https://jay.zcloud.cz/legal/channels-${languageCode == 'cs' ? 'cs' : 'en'}.html#$rule',
  );
}

class AdminSession {
  AdminSession({
    required this.token,
    required this.expiresAt,
    required this.accountId,
    required this.email,
  });

  final String token;
  final DateTime expiresAt;
  final String accountId;
  final String email;

  factory AdminSession.fromJson(Map<String, dynamic> j) => AdminSession(
    token: _str(j['token']),
    expiresAt: _tsReq(j['expiresAt']),
    accountId: _str(j['accountId']),
    email: _str(j['email']),
  );
}

class AdminSummary {
  AdminSummary({
    required this.openReports,
    required this.openSubjects,
    required this.oldestOpenAt,
    required this.suspendedChannels,
    required this.decisionsLast30Days,
  });

  final int openReports;
  final int openSubjects;
  final DateTime? oldestOpenAt;
  final int suspendedChannels;
  final int decisionsLast30Days;

  factory AdminSummary.fromJson(Map<String, dynamic> j) => AdminSummary(
    openReports: _int(j['openReports']),
    openSubjects: _int(j['openSubjects']),
    oldestOpenAt: _ts(j['oldestOpenAt']),
    suspendedChannels: _int(j['suspendedChannels']),
    decisionsLast30Days: _int(j['decisionsLast30Days']),
  );
}

class ChannelSummary {
  ChannelSummary({
    required this.channelId,
    required this.handle,
    required this.name,
    required this.description,
    required this.followerCount,
    required this.status,
    required this.suspendedUntil,
    required this.deleted,
    required this.createdAt,
    required this.ownerHandle,
  });

  final String channelId;
  final String handle;
  final String name;
  final String description;
  final int followerCount;
  final String status;
  final DateTime? suspendedUntil;
  final bool deleted;
  final DateTime createdAt;
  final String ownerHandle;

  bool get isSuspended => !deleted && status == 'suspended';

  factory ChannelSummary.fromJson(Map<String, dynamic> j) => ChannelSummary(
    channelId: _str(j['channelId']),
    handle: _str(j['handle']),
    name: _str(j['name']),
    description: _str(j['description']),
    followerCount: _int(j['followerCount']),
    status: _strOrNull(j['status']) ?? 'active',
    suspendedUntil: _ts(j['suspendedUntil']),
    deleted: j['deleted'] == true,
    createdAt: _tsReq(j['createdAt']),
    ownerHandle: _str(j['ownerHandle']),
  );
}

class PostSummary {
  PostSummary({
    required this.postId,
    required this.kind,
    required this.body,
    required this.attachmentBlobPath,
    required this.createdAt,
    required this.deleted,
    required this.byBot,
  });

  final String postId;
  final String kind;
  final String body;
  final String? attachmentBlobPath;
  final DateTime createdAt;
  final bool deleted;
  final bool byBot;

  /// Blob paths are `channel-media/{channelId}/{name}`; the admin download
  /// route wants only `{name}`.
  String? get attachmentName {
    final p = attachmentBlobPath;
    if (p == null || p.isEmpty) return null;
    final i = p.lastIndexOf('/');
    return i < 0 ? p : p.substring(i + 1);
  }

  factory PostSummary.fromJson(Map<String, dynamic> j) => PostSummary(
    postId: _str(j['postId']),
    kind: _strOrNull(j['kind']) ?? 'text',
    body: _str(j['body']),
    attachmentBlobPath: _strOrNull(j['attachmentBlobPath']),
    createdAt: _tsReq(j['createdAt']),
    deleted: j['deleted'] == true,
    byBot: j['byBot'] == true,
  );
}

/// A decision as the operator API returns it (Statement + audit fields).
class Decision {
  Decision({
    required this.decisionId,
    required this.action,
    required this.postId,
    required this.ground,
    required this.rule,
    required this.legalGround,
    required this.explanation,
    required this.suspendedUntil,
    required this.basedOnReports,
    required this.createdAt,
    required this.operatorAccountId,
    required this.reportCount,
    required this.channelId,
  });

  final int decisionId;
  final String action;
  final String? postId;
  final String? ground;
  final String? rule;
  final String? legalGround;
  final String explanation;
  final DateTime? suspendedUntil;
  final bool basedOnReports;
  final DateTime createdAt;
  final String operatorAccountId;
  final int reportCount;
  final String channelId;

  factory Decision.fromJson(Map<String, dynamic> j) => Decision(
    decisionId: _int(j['decisionId']),
    action: _str(j['action']),
    postId: _strOrNull(j['postId']),
    ground: _strOrNull(j['ground']),
    rule: _strOrNull(j['rule']),
    legalGround: _strOrNull(j['legalGround']),
    explanation: _str(j['explanation']),
    suspendedUntil: _ts(j['suspendedUntil']),
    basedOnReports: j['basedOnReports'] == true,
    createdAt: _tsReq(j['createdAt']),
    operatorAccountId: _str(j['operatorAccountId']),
    reportCount: _int(j['reportCount']),
    channelId: _str(j['channelId']),
  );
}

class Subject {
  Subject({
    required this.subjectType,
    required this.channelId,
    required this.postId,
    required this.status,
    required this.reportCount,
    required this.categories,
    required this.firstReportedAt,
    required this.lastReportedAt,
    required this.latestReason,
    required this.channel,
    required this.post,
    required this.priorDecisions,
  });

  final String subjectType;
  final String channelId;
  final String? postId;
  final String status;
  final int reportCount;
  final Map<String, int> categories;
  final DateTime firstReportedAt;
  final DateTime lastReportedAt;
  final String latestReason;
  final ChannelSummary channel;
  final PostSummary? post;
  final List<Decision> priorDecisions;

  factory Subject.fromJson(Map<String, dynamic> j) => Subject(
    subjectType: _strOrNull(j['subjectType']) ?? 'channel',
    channelId: _str(j['channelId']),
    postId: _strOrNull(j['postId']),
    status: _strOrNull(j['status']) ?? 'open',
    reportCount: _int(j['reportCount']),
    categories: {
      for (final e in ((j['categories'] as Map?) ?? const {}).entries)
        '${e.key}': _int(e.value),
    },
    firstReportedAt: _tsReq(j['firstReportedAt']),
    lastReportedAt: _tsReq(j['lastReportedAt']),
    latestReason: _str(j['latestReason']),
    channel: ChannelSummary.fromJson(
      ((j['channel'] as Map?) ?? const {}).cast<String, dynamic>(),
    ),
    post: j['post'] is Map
        ? PostSummary.fromJson((j['post'] as Map).cast<String, dynamic>())
        : null,
    priorDecisions: _list(j['priorDecisions'], Decision.fromJson),
  );
}

class ReportPage {
  ReportPage({
    required this.items,
    required this.openCount,
    required this.resolvedCount,
    required this.nextCursor,
  });

  final List<Subject> items;
  final int openCount;
  final int resolvedCount;
  final String? nextCursor;

  factory ReportPage.fromJson(Map<String, dynamic> j) {
    final counts = ((j['counts'] as Map?) ?? const {}).cast<String, dynamic>();
    return ReportPage(
      items: _list(j['items'], Subject.fromJson),
      openCount: _int(counts['open']),
      resolvedCount: _int(counts['resolved']),
      nextCursor: j['nextCursor'] == null ? null : '${j['nextCursor']}',
    );
  }
}

class ReportItem {
  ReportItem({
    required this.reportId,
    required this.category,
    required this.reason,
    required this.contactEmail,
    required this.goodFaith,
    required this.createdAt,
    required this.status,
  });

  final int reportId;
  final String category;
  final String reason;
  final String? contactEmail;
  final bool goodFaith;
  final DateTime createdAt;
  final String status;

  factory ReportItem.fromJson(Map<String, dynamic> j) => ReportItem(
    reportId: _int(j['reportId']),
    category: _strOrNull(j['category']) ?? 'terms',
    reason: _str(j['reason']),
    contactEmail: _strOrNull(j['contactEmail']),
    goodFaith: j['goodFaith'] == true,
    createdAt: _tsReq(j['createdAt']),
    status: _strOrNull(j['status']) ?? 'open',
  );
}

class CaseDetail {
  CaseDetail({
    required this.channel,
    required this.post,
    required this.context,
    required this.reports,
    required this.decisions,
  });

  final ChannelSummary channel;
  final PostSummary? post;
  final List<PostSummary> context;
  final List<ReportItem> reports;
  final List<Decision> decisions;

  int get openReports => reports.where((r) => r.status == 'open').length;

  factory CaseDetail.fromJson(Map<String, dynamic> j) => CaseDetail(
    channel: ChannelSummary.fromJson(
      ((j['channel'] as Map?) ?? const {}).cast<String, dynamic>(),
    ),
    post: j['post'] is Map
        ? PostSummary.fromJson((j['post'] as Map).cast<String, dynamic>())
        : null,
    context: _list(j['context'], PostSummary.fromJson),
    reports: _list(j['reports'], ReportItem.fromJson),
    decisions: _list(j['decisions'], Decision.fromJson),
  );
}

/// Body of `POST /admin/decisions`.
class DecisionRequest {
  DecisionRequest({
    required this.channelId,
    this.postId,
    required this.action,
    this.ground,
    this.rule,
    this.legalGround,
    required this.explanation,
    this.suspendDays,
  });

  final String channelId;
  final String? postId;
  final String action;
  final String? ground;
  final String? rule;
  final String? legalGround;
  final String explanation;
  final int? suspendDays;

  Map<String, dynamic> toJson() => {
    'channelId': channelId,
    'postId': ?postId,
    'action': action,
    'ground': ?ground,
    'rule': ?rule,
    'legalGround': ?legalGround,
    'explanation': explanation,
    'suspendDays': ?suspendDays,
  };
}

List<T> _list<T>(Object? data, T Function(Map<String, dynamic>) parse) {
  final list = data is Map ? data['items'] : data;
  if (list is! List) return <T>[];
  return [
    for (final item in list)
      if (item is Map) parse(item.cast<String, dynamic>()),
  ];
}

/// Public for the channel search and audit endpoints that return bare arrays.
List<T> parseList<T>(Object? data, T Function(Map<String, dynamic>) parse) =>
    _list(data, parse);
