/// Who the LLM bridge answers (spec 2026-11-09-bot-access A4/A5), as pure
/// logic over a [GroupInfo] so the rules are unit-tested without a hub.
library;

import 'package:calltype_bot/calltype_bot.dart';

/// Env `GROUP_REPLIES`.
enum GroupReplies {
  /// In a group with at least one owner as member, any HUMAN member who
  /// addresses the bot is answered (A4, the default).
  members,

  /// Only owners, also in groups (the behaviour before A4).
  owners;

  static GroupReplies? parse(String raw) => switch (raw.trim().toLowerCase()) {
    'members' => members,
    'owners' => owners,
    _ => null,
  };
}

/// What to do with one incoming message.
sealed class AccessDecision {
  const AccessDecision();
}

/// Answer it; [label] (handle or name) prefixes the turn in groups so the
/// model knows who speaks. Null in 1:1 chats with an owner.
class Answer extends AccessDecision {
  const Answer(this.label);
  final String? label;
}

/// Do not answer, and say nothing.
class Ignore extends AccessDecision {
  const Ignore(this.reason);

  /// For logs and tests.
  final String reason;
}

/// A bot exchange just hit its limit: post the one notice, no answer.
class BotLimitNotice extends AccessDecision {
  const BotLimitNotice();
}

/// The rules. [owners]: owner identity id (lower-case) -> handle.
///
/// WHY humans other than owners only in groups WITH an owner: every answer
/// is paid from the owner's subscription or API key, and the owner sees
/// what the bot says there. A group without him is somebody else's room.
/// The server applies the same group rule (A2) when the bot published its
/// policy; this is the bot's own, independent check.
class LlmAccess {
  LlmAccess({
    required Map<String, String> owners,
    required this.groupReplies,
    required this.botTalk,
  }) : _owners = {for (final e in owners.entries) e.key.toLowerCase(): e.value};

  final Map<String, String> _owners;
  final GroupReplies groupReplies;

  /// Bot-to-bot rules shared with hermes_bridge; built with
  /// [OwnerRule.member] by the glue (A5).
  final BotTalkPolicy botTalk;

  String? ownerHandle(String id) => _owners[id.toLowerCase()];

  /// Cheap pre-decrypt check: owners always.
  bool allowSender(String id) => ownerHandle(id) != null;

  /// Pre-decrypt second chance for a non-owner in [group]: a human member
  /// when [groupReplies] allows it and an owner is in the group, or a bot
  /// that the group's bot-talk setting admits. Counting happens later in
  /// [decide], on the authenticated group id.
  bool admitGroupSender(GroupInfo group, String senderId) {
    final member = group.member(senderId);
    if (member == null) return false;
    if (member.isBot) return botTalk.eligible(group, senderId) == null;
    return groupReplies == GroupReplies.members && botTalk.hasOwner(group);
  }

  /// The decision for a message from [senderId]; [group] is null in 1:1.
  /// An allowed bot turn is counted here (call once per message).
  AccessDecision decide(String senderId, GroupInfo? group) {
    final owner = ownerHandle(senderId);
    if (group == null) {
      // WHY no strangers and no bots in 1:1: a private chat has no owner
      // watching it, and a bot-to-bot 1:1 has no human at all.
      return owner == null
          ? const Ignore('not an owner (1:1)')
          : const Answer(null);
    }
    if (owner != null) {
      botTalk.humanSpoke(group.groupId);
      return Answer(owner);
    }
    final member = group.member(senderId);
    if (member == null) return const Ignore('not a group member');
    if (member.isBot) {
      return switch (botTalk.checkIncoming(group, senderId)) {
        PeerVerdict.allow => Answer('${_name(member, senderId)} (bot)'),
        PeerVerdict.notify => const BotLimitNotice(),
        PeerVerdict.drop => const Ignore('bot talk not allowed here'),
      };
    }
    if (groupReplies == GroupReplies.owners) {
      return const Ignore('GROUP_REPLIES=owners');
    }
    if (!botTalk.hasOwner(group)) return const Ignore('no owner in the group');
    // A human addressing the bot re-arms bot talk, like an owner does.
    botTalk.humanSpoke(group.groupId);
    return Answer(_name(member, senderId));
  }

  static String _name(GroupMember m, String id) =>
      m.handle ?? m.displayName ?? id;
}
