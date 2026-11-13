import 'package:calltype_core/network/group_dtos.dart';

/// One member of a group, as the bot sees it (`GET /groups/{id}/members`).
class GroupMember {
  const GroupMember({
    required this.deviceId,
    this.role = 'member',
    this.handle,
    this.displayName,
    this.isBot = false,
  });

  /// The member's identity id (primary device), lower-cased.
  final String deviceId;

  /// `admin`, `member` or `auditor`.
  final String role;

  /// `CT-XXXX-XXXX`; null on servers older than the profile fields.
  final String? handle;
  final String? displayName;
  final bool isBot;

  bool get isAdmin => role == 'admin';
}

/// What a bot needs to know about a group to decide whether it may talk:
/// the owner's bot-talk setting plus who is in it and with which role.
class GroupInfo {
  GroupInfo({
    required this.groupId,
    this.botTalk = BotTalkSettings.off,
    this.myMute = MuteSetting.off,
    this.topic,
    required List<GroupMember> members,
  }) : members = List.unmodifiable(members),
       _byId = {for (final m in members) m.deviceId.toLowerCase(): m};

  final String groupId;
  final BotTalkSettings botTalk;
  final MuteSetting myMute;

  /// The server's record of the group topic (version + who set it, never
  /// the text: that arrives E2E as `group-topic`); null = never set or an
  /// old server. Spec 2026-11-13-group-topics row 6.
  final GroupTopicRecord? topic;
  final List<GroupMember> members;
  final Map<String, GroupMember> _byId;

  /// The member with identity [deviceId] (case-insensitive), or null.
  GroupMember? member(String deviceId) => _byId[deviceId.toLowerCase()];

  bool isMember(String deviceId) => member(deviceId) != null;
}
