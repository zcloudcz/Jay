/// DTOs for the group "bot conversation" setting and per-device mutes
/// (docs/superpowers/specs/2026-11-05-bot-conversations-contract.md).
///
/// WHY every parser is lenient: servers deployed before this feature answer
/// `GET /groups/{id}` without `botTalk`/`myMute`, and an unknown enum value
/// from a newer server must not crash an older client. Anything missing or
/// unknown therefore falls back to the safe default, which is always "off"
/// (no bot talk, no mute): a bot never talks MORE because of bad data.
library;

/// Who may talk to whom among the bots of a group.
enum BotTalkMode {
  off,
  all,
  selected;

  /// Unknown or missing -> [off] (fail closed).
  static BotTalkMode parse(Object? raw) => switch (raw) {
    'all' => all,
    'selected' => selected,
    _ => off,
  };
}

/// `botTalk` of `GET /groups/{id}` and the body/answer of
/// `PUT /groups/{id}/bot-talk`.
class BotTalkSettings {
  const BotTalkSettings({
    this.mode = BotTalkMode.off,
    this.allowedBotDeviceIds = const [],
    this.maxBotTurns = defaultMaxBotTurns,
    this.pauseMinutes = defaultPauseMinutes,
    this.updatedAt,
    this.botsReadAll = false,
    this.replyWithoutMention = false,
  });

  /// Server defaults (design doc "Group setting").
  static const defaultMaxBotTurns = 5;
  static const defaultPauseMinutes = 30;

  /// What an old server (no `botTalk` field) means: bot talk is off.
  static const off = BotTalkSettings();

  final BotTalkMode mode;

  /// Device ids (GUID strings, lower-cased); meaningful for [BotTalkMode.selected].
  final List<String> allowedBotDeviceIds;
  final int maxBotTurns;
  final int pauseMinutes;

  /// Null when the setting was never changed.
  final DateTime? updatedAt;

  /// Group topics T3 (spec 2026-11-13-group-topics row 19): member bots get
  /// every group message as context, not only the ones addressed to them.
  /// Off on an old server (field missing).
  final bool botsReadAll;

  /// Group topics T4 (row 20): a human member's message counts as addressed
  /// to every bot without an @mention. Bot messages still need one.
  final bool replyWithoutMention;

  BotTalkSettings copyWith({
    BotTalkMode? mode,
    List<String>? allowedBotDeviceIds,
    int? maxBotTurns,
    int? pauseMinutes,
    bool? botsReadAll,
    bool? replyWithoutMention,
  }) => BotTalkSettings(
    mode: mode ?? this.mode,
    allowedBotDeviceIds: allowedBotDeviceIds ?? this.allowedBotDeviceIds,
    maxBotTurns: maxBotTurns ?? this.maxBotTurns,
    pauseMinutes: pauseMinutes ?? this.pauseMinutes,
    updatedAt: updatedAt,
    botsReadAll: botsReadAll ?? this.botsReadAll,
    replyWithoutMention: replyWithoutMention ?? this.replyWithoutMention,
  );

  /// True when [deviceId] is listed in [allowedBotDeviceIds] (case-insensitive:
  /// .NET serialises GUIDs lower-case, but a hand-written id may not be).
  bool allows(String deviceId) {
    final id = deviceId.toLowerCase();
    return allowedBotDeviceIds.any((a) => a.toLowerCase() == id);
  }

  /// Null or a non-map -> [off]. Bad numbers fall back to the defaults
  /// instead of throwing, for the reason in the library comment.
  factory BotTalkSettings.fromJson(Object? json) {
    if (json is! Map) return off;
    final ids = json['allowedBotDeviceIds'];
    return BotTalkSettings(
      mode: BotTalkMode.parse(json['mode']),
      allowedBotDeviceIds: ids is List
          ? [
              for (final id in ids)
                if (id is String) id.toLowerCase(),
            ]
          : const [],
      maxBotTurns: _int(json['maxBotTurns']) ?? defaultMaxBotTurns,
      pauseMinutes: _int(json['pauseMinutes']) ?? defaultPauseMinutes,
      updatedAt: _date(json['updatedAt']),
      // Only a real `true` switches a bot to reading/answering more.
      botsReadAll: json['botsReadAll'] == true,
      replyWithoutMention: json['replyWithoutMention'] == true,
    );
  }

  /// The `PUT /groups/{id}/bot-talk` body (updatedAt is server-owned). An
  /// old server ignores the two group-topics flags.
  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'allowedBotDeviceIds': allowedBotDeviceIds,
    'maxBotTurns': maxBotTurns,
    'pauseMinutes': pauseMinutes,
    'botsReadAll': botsReadAll,
    'replyWithoutMention': replyWithoutMention,
  };
}

/// How much of a conversation a device muted.
enum MuteMode {
  off,

  /// Only pushes for messages sent by bot devices are skipped.
  bots,
  all;

  /// Unknown or missing -> [off].
  static MuteMode parse(Object? raw) => switch (raw) {
    'bots' => bots,
    'all' => all,
    _ => off,
  };
}

/// `myMute` of `GET /groups/{id}` and the body of the mute PUTs.
class MuteSetting {
  const MuteSetting({this.mode = MuteMode.off, this.until});

  static const off = MuteSetting();

  final MuteMode mode;

  /// Null = until changed again.
  final DateTime? until;

  /// An expired [until] means "not muted" (same rule as the server's push skip).
  MuteMode effectiveMode(DateTime now) =>
      until != null && !now.isBefore(until!) ? MuteMode.off : mode;

  factory MuteSetting.fromJson(Object? json) => json is Map
      ? MuteSetting(
          mode: MuteMode.parse(json['mode']),
          until: _date(json['until']),
        )
      : off;

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'until': until?.toUtc().toIso8601String(),
  };
}

/// One row of `GET /mutes`: exactly one of [groupId] / [peerDeviceId] is set.
class MuteEntry {
  const MuteEntry({this.groupId, this.peerDeviceId, required this.setting});

  final String? groupId;
  final String? peerDeviceId;
  final MuteSetting setting;

  factory MuteEntry.fromJson(Map<dynamic, dynamic> json) => MuteEntry(
    groupId: json['groupId'] as String?,
    peerDeviceId: json['peerDeviceId'] as String?,
    setting: MuteSetting.fromJson(json),
  );
}

/// The server's record of a group's topic (spec 2026-11-13-group-topics
/// row 6): which version an admin set, never the content (that is E2E).
/// `topic` of `GET /groups/{id}` and the answer of `PUT /groups/{id}/topic`.
class GroupTopicRecord {
  const GroupTopicRecord({
    required this.version,
    required this.updatedBy,
    this.updatedAt,
  });

  /// Server-assigned, strictly increasing per group.
  final int version;

  /// Device id (= identity, companions cannot manage groups) of the admin
  /// who recorded [version], lower-cased.
  final String updatedBy;
  final DateTime? updatedAt;

  /// True when a received `group-topic` with [version] from [senderIdentity]
  /// is exactly this record (receiver rule 3 of the spec).
  bool matches(int version, String senderIdentity) =>
      this.version == version && updatedBy == senderIdentity.toLowerCase();

  /// Null for a missing, non-map or incomplete record (never set, or an
  /// old server): no topic can be accepted then.
  static GroupTopicRecord? fromJson(Object? json) {
    if (json is! Map) return null;
    final version = json['version'];
    final by = json['updatedBy'];
    if (version is! int || version <= 0 || by is! String || by.isEmpty) {
      return null;
    }
    return GroupTopicRecord(
      version: version,
      updatedBy: by.toLowerCase(),
      updatedAt: _date(json['updatedAt']),
    );
  }
}

/// `GET /groups/{id}`. Only the fields this feature needs are typed; the
/// rest (organization, auditor) stays in [raw] for existing callers.
class GroupDetails {
  const GroupDetails({
    required this.groupId,
    this.botTalk = BotTalkSettings.off,
    this.myMute = MuteSetting.off,
    this.topic,
    this.raw = const {},
  });

  final String groupId;
  final BotTalkSettings botTalk;
  final MuteSetting myMute;

  /// Null = no topic was ever recorded (or an old server).
  final GroupTopicRecord? topic;
  final Map<String, dynamic> raw;

  factory GroupDetails.fromJson(String groupId, Map<String, dynamic> json) =>
      GroupDetails(
        groupId: (json['groupId'] as String?) ?? groupId,
        botTalk: BotTalkSettings.fromJson(json['botTalk']),
        myMute: MuteSetting.fromJson(json['myMute']),
        topic: GroupTopicRecord.fromJson(json['topic']),
        raw: json,
      );
}

int? _int(Object? raw) => raw is num ? raw.toInt() : null;

DateTime? _date(Object? raw) => raw is String ? DateTime.tryParse(raw) : null;
