/// Abuse limits of the public 1:1 mode (spec 2026-11-27-bot-public-dm
/// P6-P8), as pure logic with an injectable clock so they are unit-tested.
library;

/// Defaults, in one place so README, scripts and tests agree.
abstract final class PublicDmDefaults {
  /// Messages per stranger per sliding hour (`LLM_PUBLIC_RATE`).
  static const rate = 20;

  /// Stranger messages of all senders per sliding 24 h (`LLM_PUBLIC_DAILY`).
  static const daily = 200;

  /// Answers per peer bot per sliding hour (`LLM_PUBLIC_BOT_RATE`).
  static const botRate = 5;
}

/// What to do with one stranger message.
enum PublicVerdict {
  /// Answer it (counted).
  allow,

  /// Over the sender's hourly limit: send the one notice of this hour.
  senderLimitNotice,

  /// Over the daily cap of all strangers: send the one notice of this hour.
  dailyLimitNotice,

  /// Over a limit and the notice already went out (or the sender is a bot):
  /// say nothing.
  drop,
}

/// Counts stranger messages per sender and globally, in sliding windows.
///
/// WHY sliding windows (timestamps) instead of fixed buckets: a fixed hour
/// lets a sender send 2x the limit across a bucket boundary. The logs are
/// bounded by the limits themselves (at most [rate] or [daily] entries).
///
/// WHY in memory only: the limits protect the owner's key against a flood
/// now; a restart resetting them is acceptable (spec Limits).
class PublicDmLimiter {
  PublicDmLimiter({
    this.rate = PublicDmDefaults.rate,
    this.daily = PublicDmDefaults.daily,
    this.botRate = PublicDmDefaults.botRate,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final int rate;
  final int daily;
  final int botRate;
  final DateTime Function() _now;

  static const _hour = Duration(hours: 1);
  static const _day = Duration(hours: 24);

  final _senders = <String, _Sender>{};
  final _global = <DateTime>[];
  var _checks = 0;

  /// One message from stranger [senderId]; an allowed one is counted.
  ///
  /// [isBot]: a peer bot gets [botRate] instead of [rate] and NEVER a
  /// notice. A notice is a message, and another bot might answer it, so
  /// two bots could ping-pong limit notices forever (P8).
  PublicVerdict check(String senderId, {required bool isBot}) {
    final now = _now();
    if (++_checks % 256 == 0) _prune(now);
    final sender = _senders.putIfAbsent(senderId.toLowerCase(), _Sender.new);
    _trim(sender.sent, now.subtract(_hour));
    _trim(_global, now.subtract(_day));
    final limit = isBot ? botRate : rate;
    if (sender.sent.length >= limit) {
      return _notice(sender, now, isBot, PublicVerdict.senderLimitNotice);
    }
    if (_global.length >= daily) {
      return _notice(sender, now, isBot, PublicVerdict.dailyLimitNotice);
    }
    sender.sent.add(now);
    _global.add(now);
    return PublicVerdict.allow;
  }

  PublicVerdict _notice(
    _Sender sender,
    DateTime now,
    bool isBot,
    PublicVerdict notice,
  ) {
    if (isBot) return PublicVerdict.drop;
    final last = sender.noticeAt;
    if (last != null && now.difference(last) < _hour) {
      return PublicVerdict.drop;
    }
    sender.noticeAt = now;
    return notice;
  }

  static void _trim(List<DateTime> log, DateTime since) {
    var drop = 0;
    while (drop < log.length && !log[drop].isAfter(since)) {
      drop++;
    }
    if (drop > 0) log.removeRange(0, drop);
  }

  /// Forgets senders with nothing in the last hour, so the map does not
  /// grow with every stranger ever seen.
  void _prune(DateTime now) {
    final since = now.subtract(_hour);
    _senders.removeWhere((_, s) {
      _trim(s.sent, since);
      final notice = s.noticeAt;
      return s.sent.isEmpty && (notice == null || !notice.isAfter(since));
    });
  }

  /// Senders currently tracked (tests).
  int get trackedSenders => _senders.length;
}

class _Sender {
  final sent = <DateTime>[];
  DateTime? noticeAt;
}
