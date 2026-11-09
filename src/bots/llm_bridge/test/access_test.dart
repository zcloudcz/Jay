import 'package:calltype_bot/calltype_bot.dart';
import 'package:llm_bridge/llm_bridge.dart';
import 'package:test/test.dart';

/// Who llm_bridge answers (spec 2026-11-09-bot-access A4/A5), on plain
/// [GroupInfo] values: no crypto, no hub.
void main() {
  const self = 'b0-self';
  const owner = 'a1-owner';
  const member = 'h1-member';
  const peer = 'p1-peer';

  var t = DateTime.utc(2026, 11, 9, 12);
  setUp(() => t = DateTime.utc(2026, 11, 9, 12));

  LlmAccess access({GroupReplies replies = GroupReplies.members}) => LlmAccess(
    owners: {owner: 'CT-OWNR-0001'},
    groupReplies: replies,
    botTalk: BotTalkPolicy(
      selfDeviceId: self,
      ownerIds: {owner},
      ownerRule: OwnerRule.member,
      now: () => t,
    ),
  );

  GroupInfo makeGroup({
    bool withOwner = true,
    BotTalkMode talk = BotTalkMode.all,
    int maxTurns = 2,
  }) => GroupInfo(
    groupId: 'g1',
    botTalk: BotTalkSettings(
      mode: talk,
      allowedBotDeviceIds: const [],
      maxBotTurns: maxTurns,
      pauseMinutes: 30,
    ),
    members: [
      const GroupMember(deviceId: self, isBot: true),
      // The owner is a plain member: A4/A5 need no admin role.
      if (withOwner) const GroupMember(deviceId: owner),
      const GroupMember(deviceId: member, handle: 'CT-MEMB-0002'),
      const GroupMember(deviceId: peer, isBot: true, displayName: 'Peer'),
    ],
  );

  String? labelOf(AccessDecision d) => switch (d) {
    Answer(:final label) => label,
    _ => throw StateError('expected Answer, got $d'),
  };

  group('1:1', () {
    test('owner is answered without a label', () {
      expect(labelOf(access().decide(owner, null)), isNull);
    });
    test('strangers and bots are not', () {
      expect(access().decide(member, null), isA<Ignore>());
      expect(access().decide(peer, null), isA<Ignore>());
      expect(access().allowSender(member), isFalse);
      expect(access().allowSender(owner.toUpperCase()), isTrue);
    });
  });

  group('humans in groups (A4)', () {
    test('a member of a group with an owner is answered, labelled', () {
      final a = access();
      expect(a.admitGroupSender(makeGroup(), member), isTrue);
      expect(labelOf(a.decide(member, makeGroup())), 'CT-MEMB-0002');
      expect(labelOf(a.decide(owner, makeGroup())), 'CT-OWNR-0001');
    });

    test('no owner in the group: ignored, also before decryption', () {
      final a = access();
      final g = makeGroup(withOwner: false);
      expect(a.admitGroupSender(g, member), isFalse);
      expect(a.decide(member, g), isA<Ignore>());
    });

    test('GROUP_REPLIES=owners: only owners, as before', () {
      final a = access(replies: GroupReplies.owners);
      expect(a.admitGroupSender(makeGroup(), member), isFalse);
      expect(a.decide(member, makeGroup()), isA<Ignore>());
      expect(labelOf(a.decide(owner, makeGroup())), 'CT-OWNR-0001');
    });

    test('a non-member is never answered', () {
      expect(access().admitGroupSender(makeGroup(), 'zz-stranger'), isFalse);
      expect(access().decide('zz-stranger', makeGroup()), isA<Ignore>());
    });
  });

  group('bots in groups (A5, the hermes_bridge rules)', () {
    test('bot talk on, owner a member: answered with a "(bot)" label', () {
      final a = access();
      expect(a.admitGroupSender(makeGroup(), peer), isTrue);
      expect(labelOf(a.decide(peer, makeGroup())), 'Peer (bot)');
    });

    test('bot talk off or no owner: ignored', () {
      final a = access();
      expect(
        a.admitGroupSender(makeGroup(talk: BotTalkMode.off), peer),
        isFalse,
      );
      expect(a.decide(peer, makeGroup(talk: BotTalkMode.off)), isA<Ignore>());
      expect(a.decide(peer, makeGroup(withOwner: false)), isA<Ignore>());
    });

    test('limit: N turns, one notice, silence; a human re-arms it', () {
      final a = access();
      final g = makeGroup(maxTurns: 2);
      expect(a.decide(peer, g), isA<Answer>());
      expect(a.decide(peer, g), isA<Answer>());
      expect(a.decide(peer, g), isA<BotLimitNotice>());
      expect(a.decide(peer, g), isA<Ignore>());
      // A member (not only an owner) speaking to the bot starts a new exchange.
      expect(a.decide(member, g), isA<Answer>());
      expect(a.decide(peer, g), isA<Answer>());
    });

    test('PEER_MAX_TURNS_CAP caps the group limit', () {
      final a = LlmAccess(
        owners: {owner: 'CT-OWNR-0001'},
        groupReplies: GroupReplies.members,
        botTalk: BotTalkPolicy(
          selfDeviceId: self,
          ownerIds: {owner},
          ownerRule: OwnerRule.member,
          turnsCap: 1,
          now: () => t,
        ),
      );
      final g = makeGroup(maxTurns: 5);
      expect(a.decide(peer, g), isA<Answer>());
      expect(a.decide(peer, g), isA<BotLimitNotice>());
    });
  });
}
