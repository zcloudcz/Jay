import 'package:llm_bridge/llm_bridge.dart';
import 'package:test/test.dart';

/// The abuse limits of the public 1:1 mode (spec 2026-11-27-bot-public-dm
/// P6-P8) on a fake clock.
void main() {
  var t = DateTime.utc(2026, 11, 27, 12);
  setUp(() => t = DateTime.utc(2026, 11, 27, 12));

  PublicDmLimiter limiter({int rate = 3, int daily = 100, int botRate = 2}) =>
      PublicDmLimiter(rate: rate, daily: daily, botRate: botRate, now: () => t);

  test('defaults', () {
    final l = PublicDmLimiter();
    expect((l.rate, l.daily, l.botRate), (20, 200, 5));
  });

  test('per sender: limit, one notice per hour, sliding window', () {
    final l = limiter();
    for (var i = 0; i < 3; i++) {
      expect(l.check('a', isBot: false), PublicVerdict.allow);
      t = t.add(const Duration(minutes: 10));
    }
    expect(l.check('a', isBot: false), PublicVerdict.senderLimitNotice);
    expect(l.check('a', isBot: false), PublicVerdict.drop);
    // Another sender is not affected; ids are case-insensitive.
    expect(l.check('b', isBot: false), PublicVerdict.allow);
    expect(l.check('A', isBot: false), PublicVerdict.drop);
    // The first message leaves the window 60 min after it was sent.
    t = DateTime.utc(2026, 11, 27, 13, 0, 1);
    expect(l.check('a', isBot: false), PublicVerdict.allow);
    expect(l.check('a', isBot: false), PublicVerdict.drop);
  });

  test('a notice repeats at most once per hour', () {
    final l = limiter(rate: 1);
    expect(l.check('a', isBot: false), PublicVerdict.allow);
    expect(l.check('a', isBot: false), PublicVerdict.senderLimitNotice);
    t = t.add(const Duration(minutes: 30));
    expect(l.check('a', isBot: false), PublicVerdict.drop);
    t = t.add(const Duration(minutes: 31));
    // Window free again: answered, then over the limit with a new notice.
    expect(l.check('a', isBot: false), PublicVerdict.allow);
    expect(l.check('a', isBot: false), PublicVerdict.senderLimitNotice);
  });

  test('daily cap over all strangers, sliding 24 h', () {
    final l = limiter(rate: 100, daily: 3);
    expect(l.check('a', isBot: false), PublicVerdict.allow);
    expect(l.check('b', isBot: false), PublicVerdict.allow);
    expect(l.check('c', isBot: true), PublicVerdict.allow);
    expect(l.check('d', isBot: false), PublicVerdict.dailyLimitNotice);
    expect(l.check('d', isBot: false), PublicVerdict.drop);
    expect(l.check('e', isBot: false), PublicVerdict.dailyLimitNotice);
    // A refused message is not counted, so the cap frees up on time.
    t = t.add(const Duration(hours: 24, seconds: 1));
    expect(l.check('d', isBot: false), PublicVerdict.allow);
  });

  test('bots: own limit, never a notice; 0 = never answered', () {
    final l = limiter();
    expect(l.check('bot', isBot: true), PublicVerdict.allow);
    expect(l.check('bot', isBot: true), PublicVerdict.allow);
    expect(l.check('bot', isBot: true), PublicVerdict.drop);
    final none = limiter(botRate: 0);
    expect(none.check('bot', isBot: true), PublicVerdict.drop);
    final full = limiter(daily: 1);
    expect(full.check('x', isBot: false), PublicVerdict.allow);
    expect(full.check('bot', isBot: true), PublicVerdict.drop);
  });

  test('idle senders are forgotten', () {
    final l = limiter();
    for (var i = 0; i < 300; i++) {
      l.check('s$i', isBot: false);
    }
    expect(l.trackedSenders, greaterThan(250));
    t = t.add(const Duration(hours: 2));
    for (var i = 0; i < 256; i++) {
      l.check('n', isBot: false);
    }
    expect(l.trackedSenders, 1);
  });
}
