import 'package:calltype_bot/calltype_bot.dart';
import 'package:test/test.dart';

/// The bot-to-bot rules (design doc "Enforcement", rules 1-4 = a-d) without
/// any crypto: a [GroupInfo] is all the policy looks at.
void main() {
  const self = 'b0-self';
  const owner = 'a1-owner';
  const peer = 'p1-peer';
  const otherBot = 'p2-other';
  const human = 'h1-human';

  GroupInfo makeGroup({
    String id = 'g1',
    BotTalkSettings? talk,
    BotTalkMode mode = BotTalkMode.all,
    List<String> allowed = const [],
    int maxTurns = 5,
    int pause = 30,
    String ownerRole = 'admin',
  }) => GroupInfo(
    groupId: id,
    botTalk:
        talk ??
        BotTalkSettings(
          mode: mode,
          allowedBotDeviceIds: allowed,
          maxBotTurns: maxTurns,
          pauseMinutes: pause,
        ),
    members: [
      const GroupMember(deviceId: self, isBot: true),
      GroupMember(deviceId: owner, role: ownerRole),
      const GroupMember(deviceId: peer, isBot: true),
      const GroupMember(deviceId: otherBot, isBot: true),
      const GroupMember(deviceId: human),
    ],
  );

  var t = DateTime.utc(2026, 11, 5, 12);
  BotTalkPolicy policy({Set<String>? peers, int cap = 50}) => BotTalkPolicy(
    selfDeviceId: self,
    ownerIds: {owner},
    peerFilter: peers,
    turnsCap: cap,
    now: () => t,
  );
  setUp(() => t = DateTime.utc(2026, 11, 5, 12));

  group('eligibility: rules (a), (b) and PEER_BOT_HANDLES', () {
    final cases = <String, (GroupInfo, String, Set<String>?, BotTalkRefusal?)>{
      'mode all, owner admin': (makeGroup(), peer, null, null),
      'mode off': (
        makeGroup(mode: BotTalkMode.off),
        peer,
        null,
        BotTalkRefusal.off,
      ),
      'old server without botTalk => off': (
        GroupInfo(
          groupId: 'g1',
          botTalk: BotTalkSettings.fromJson(null),
          members: makeGroup().members,
        ),
        peer,
        null,
        BotTalkRefusal.off,
      ),
      'owner is only a member (not admin)': (
        makeGroup(ownerRole: 'member'),
        peer,
        null,
        BotTalkRefusal.ownerNotAdmin,
      ),
      'selected: sender and self listed': (
        makeGroup(mode: BotTalkMode.selected, allowed: [peer, self]),
        peer,
        null,
        null,
      ),
      'selected: self not listed': (
        makeGroup(mode: BotTalkMode.selected, allowed: [peer, otherBot]),
        peer,
        null,
        BotTalkRefusal.notSelected,
      ),
      'selected: sender not listed': (
        makeGroup(mode: BotTalkMode.selected, allowed: [self, otherBot]),
        peer,
        null,
        BotTalkRefusal.notSelected,
      ),
      'selected: ids compared case-insensitively': (
        makeGroup(
          mode: BotTalkMode.selected,
          allowed: [peer.toUpperCase(), self],
        ),
        peer.toUpperCase(),
        null,
        null,
      ),
      'sender is a human member, not a bot': (
        makeGroup(),
        human,
        null,
        BotTalkRefusal.notBotMember,
      ),
      'sender is not a member': (
        makeGroup(),
        'zz-stranger',
        null,
        BotTalkRefusal.notBotMember,
      ),
      'PEER_BOT_HANDLES names the sender': (makeGroup(), peer, {peer}, null),
      'PEER_BOT_HANDLES narrows: other bot only': (
        makeGroup(),
        peer,
        {otherBot},
        BotTalkRefusal.notPeer,
      ),
      'PEER_BOT_HANDLES set but nothing resolved: nobody': (
        makeGroup(),
        peer,
        <String>{},
        BotTalkRefusal.notPeer,
      ),
      'PEER_BOT_HANDLES never widens: mode off stays off': (
        makeGroup(mode: BotTalkMode.off),
        peer,
        {peer},
        BotTalkRefusal.off,
      ),
    };
    cases.forEach((name, c) {
      test(name, () {
        final (g, sender, peers, expected) = c;
        expect(policy(peers: peers).eligible(g, sender), expected);
        // An ineligible message is dropped silently (no notice) and does
        // not count.
        expect(
          policy(peers: peers).checkIncoming(g, sender),
          expected == null ? PeerVerdict.allow : PeerVerdict.drop,
        );
      });
    });
  });

  group('counting: rules (c) and (d)', () {
    // Each case: group, cap, then a script of (minutes since start, action,
    // expected verdict). Actions: 'bot' = incoming peer message, 'own' = a
    // /send post, 'human' = an owner mention (no verdict).
    final cases = <String, (GroupInfo, int, List<(int, String, PeerVerdict?)>)>{
      'group limit: N turns, one notice, then silence': (
        makeGroup(maxTurns: 3),
        50,
        [
          (0, 'bot', PeerVerdict.allow),
          (0, 'bot', PeerVerdict.allow),
          (0, 'bot', PeerVerdict.allow),
          (0, 'bot', PeerVerdict.notify),
          (1, 'bot', PeerVerdict.drop),
          (2, 'bot', PeerVerdict.drop),
        ],
      ),
      'operator cap lower than the group max wins': (
        makeGroup(maxTurns: 5),
        2,
        [
          (0, 'bot', PeerVerdict.allow),
          (0, 'bot', PeerVerdict.allow),
          (0, 'bot', PeerVerdict.notify),
        ],
      ),
      'pause: no new exchange before it passed, a fresh one after': (
        makeGroup(maxTurns: 1, pause: 30),
        50,
        [
          (0, 'bot', PeerVerdict.allow),
          (5, 'bot', PeerVerdict.notify), // exchange ends at minute 5
          (34, 'bot', PeerVerdict.drop), // 29 min after the end
          (35, 'bot', PeerVerdict.allow), // pause over, fresh counter
          (35, 'bot', PeerVerdict.notify),
        ],
      ),
      'pause 0: the next exchange may start at once': (
        makeGroup(maxTurns: 1, pause: 0),
        50,
        [
          (0, 'bot', PeerVerdict.allow),
          (0, 'bot', PeerVerdict.notify),
          (0, 'bot', PeerVerdict.allow),
        ],
      ),
      'a human mention resets counter and pause': (
        makeGroup(maxTurns: 2, pause: 600),
        50,
        [
          (0, 'bot', PeerVerdict.allow),
          (0, 'bot', PeerVerdict.allow),
          (0, 'bot', PeerVerdict.notify),
          (1, 'human', null),
          (1, 'bot', PeerVerdict.allow),
          (1, 'bot', PeerVerdict.allow),
          (1, 'bot', PeerVerdict.notify),
        ],
      ),
      "the bot's own posts count as bot turns": (
        makeGroup(maxTurns: 3),
        50,
        [
          (0, 'own', PeerVerdict.allow),
          (0, 'own', PeerVerdict.allow),
          (0, 'bot', PeerVerdict.allow),
          (0, 'own', PeerVerdict.notify), // /send answers 403
          (0, 'bot', PeerVerdict.drop), // notice already given
        ],
      ),
    };
    cases.forEach((name, c) {
      test(name, () {
        final (g, cap, script) = c;
        final p = policy(cap: cap);
        final start = t;
        for (final (i, (minute, action, expected)) in script.indexed) {
          t = start.add(Duration(minutes: minute));
          PeerVerdict? verdict;
          switch (action) {
            case 'bot':
              verdict = p.checkIncoming(g, peer);
            case 'own':
              verdict = p.checkOwnSend(g);
            default:
              p.humanSpoke(g.groupId);
          }
          expect(verdict, expected, reason: 'step $i ($minute min, $action)');
        }
      });
    });

    test('exchanges are per group', () {
      final p = policy();
      final a = makeGroup(id: 'ga', maxTurns: 1);
      final b = makeGroup(id: 'gb', maxTurns: 1);
      expect(p.checkIncoming(a, peer), PeerVerdict.allow);
      expect(p.checkIncoming(a, peer), PeerVerdict.notify);
      expect(p.checkIncoming(b, peer), PeerVerdict.allow);
    });

    test('limitFor = min(group max, cap)', () {
      expect(policy(cap: 50).limitFor(makeGroup(maxTurns: 7)), 7);
      expect(policy(cap: 3).limitFor(makeGroup(maxTurns: 7)), 3);
    });
  });

  group('owner rule member (llm_bridge, bot-access A5)', () {
    BotTalkPolicy memberRule() => BotTalkPolicy(
      selfDeviceId: self,
      ownerIds: {owner},
      ownerRule: OwnerRule.member,
      now: () => t,
    );

    test('an owner that is only a member is enough', () {
      final g = makeGroup(ownerRole: 'member');
      expect(memberRule().eligible(g, peer), isNull);
      expect(memberRule().hasOwner(g), isTrue);
      // The default rule (hermes_bridge) still wants an admin.
      expect(policy().eligible(g, peer), BotTalkRefusal.ownerNotAdmin);
    });

    test('no owner in the group: refused', () {
      final g = GroupInfo(
        groupId: 'g1',
        botTalk: makeGroup().botTalk,
        members: [
          for (final m in makeGroup().members)
            if (m.deviceId != owner) m,
        ],
      );
      expect(memberRule().eligible(g, peer), BotTalkRefusal.noOwner);
      expect(memberRule().hasOwner(g), isFalse);
      expect(memberRule().checkIncoming(g, peer), PeerVerdict.drop);
    });

    test('group settings and limits apply unchanged', () {
      final g = makeGroup(ownerRole: 'member', maxTurns: 1);
      final p = memberRule();
      expect(
        p.eligible(makeGroup(mode: BotTalkMode.off), peer),
        BotTalkRefusal.off,
      );
      expect(p.checkIncoming(g, peer), PeerVerdict.allow);
      expect(p.checkIncoming(g, peer), PeerVerdict.notify);
    });
  });
}
