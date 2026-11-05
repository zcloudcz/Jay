import 'dart:math';

import 'package:calltype_bot/calltype_bot.dart';

/// What to do with a bot turn, see [BotTalkPolicy].
enum PeerVerdict {
  /// Go ahead; the turn was counted.
  allow,

  /// Refused, and this is the FIRST refusal of the exchange: the caller
  /// sends the one notice.
  notify,

  /// Refused silently.
  drop,
}

/// Why [BotTalkPolicy.eligible] refused a bot; for logs and tests.
enum BotTalkRefusal {
  /// The group's bot talk is off (also: an old server without the setting).
  off,

  /// Mode "selected" and the sender or this bot is not on the list.
  notSelected,

  /// None of this bot's owners is an admin of the group (D5).
  ownerNotAdmin,

  /// The operator's PEER_BOT_HANDLES is set and does not name the sender.
  notPeer,

  /// The sender is not a bot member of the group.
  notBotMember,
}

/// Group-setting based rules for bot-to-bot talk (design doc "Enforcement").
///
/// WHY every bot enforces this itself: the server cannot read messages, so
/// it cannot count turns. A misbehaving bot is still contained because the
/// RECEIVING bot refuses too.
///
/// An exchange = the bot turns in a group since the last human message. It
/// ends when it reaches the limit (or a human speaks); after a limit the next
/// exchange may start only when the group's pause has passed. WHY an idle
/// exchange does not end by itself: two bots that answer slowly would
/// otherwise never hit the limit.
///
/// The clock is injected so tests need no timers.
// ponytail: in-memory only, counters reset on restart. Persist them if a
// restart loop ever becomes a way around the limit.
class BotTalkPolicy {
  BotTalkPolicy({
    required String selfDeviceId,
    required Set<String> ownerIds,
    Set<String>? peerFilter,
    this.turnsCap = 50,
    DateTime Function()? now,
  }) : _self = selfDeviceId.toLowerCase(),
       _owners = {for (final id in ownerIds) id.toLowerCase()},
       _peerFilter = peerFilter == null
           ? null
           : {for (final id in peerFilter) id.toLowerCase()},
       _now = now ?? DateTime.now;

  final String _self;
  final Set<String> _owners;

  /// Null = PEER_BOT_HANDLES not set. Set (even empty) = only these senders.
  final Set<String>? _peerFilter;

  /// The operator's hard cap (env PEER_MAX_TURNS_CAP): a group can lower the
  /// limit but never raise a bot above it.
  final int turnsCap;
  final DateTime Function() _now;
  final _exchanges = <String, _Exchange>{};

  /// The effective exchange limit in [group].
  int limitFor(GroupInfo group) =>
      max(0, min(group.botTalk.maxBotTurns, turnsCap));

  /// Rules (a) and (b) plus the operator narrowing, without counting.
  /// Null = eligible. Cheap enough for the pre-decrypt check.
  BotTalkRefusal? eligible(GroupInfo group, String senderId) {
    final sender = senderId.toLowerCase();
    final talk = group.botTalk;
    if (talk.mode == BotTalkMode.off) return BotTalkRefusal.off;
    if (_peerFilter != null && !_peerFilter.contains(sender)) {
      return BotTalkRefusal.notPeer;
    }
    if (group.member(sender)?.isBot != true) return BotTalkRefusal.notBotMember;
    if (talk.mode == BotTalkMode.selected &&
        !(talk.allows(sender) && talk.allows(_self))) {
      return BotTalkRefusal.notSelected;
    }
    if (!_ownerIsAdmin(group)) return BotTalkRefusal.ownerNotAdmin;
    return null;
  }

  /// A message from bot [senderId] in [group]: rules (a)-(d). An allowed
  /// message counts one turn of the current exchange.
  PeerVerdict checkIncoming(GroupInfo group, String senderId) =>
      eligible(group, senderId) != null ? PeerVerdict.drop : _count(group);

  /// A message this bot starts in [group] (the bridge's /send): it is a bot
  /// turn like any other, so it counts against rules (c) and (d). Rules (a)
  /// and (b) are about ANSWERING other bots and do not apply to a post.
  PeerVerdict checkOwnSend(GroupInfo group) => _count(group);

  /// An allowed human mentioned the bot in [groupId]: counter and pause reset.
  void humanSpoke(String groupId) => _exchanges.remove(groupId.toLowerCase());

  bool _ownerIsAdmin(GroupInfo group) =>
      _owners.any((id) => group.member(id)?.isAdmin ?? false);

  PeerVerdict _count(GroupInfo group) {
    final now = _now();
    final exchange = _exchanges.putIfAbsent(
      group.groupId.toLowerCase(),
      _Exchange.new,
    );
    final ended = exchange.endedAt;
    if (ended != null) {
      final pause = Duration(minutes: group.botTalk.pauseMinutes);
      // The notice already went out when the exchange hit its limit.
      if (now.difference(ended) < pause) return PeerVerdict.drop;
      // Pause over: this turn starts a new exchange.
      exchange
        ..turns = 0
        ..endedAt = null;
    }
    if (exchange.turns < limitFor(group)) {
      exchange.turns++;
      return PeerVerdict.allow;
    }
    exchange.endedAt = now;
    return PeerVerdict.notify;
  }
}

class _Exchange {
  int turns = 0;

  /// When the limit was hit; the one notice is sent at that moment.
  DateTime? endedAt;
}
