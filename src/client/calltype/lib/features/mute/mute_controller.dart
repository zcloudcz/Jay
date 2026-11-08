import 'dart:async';

import 'package:calltype_core/network/group_dtos.dart';
import 'package:flutter/foundation.dart';

import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/storage/database.dart';

/// How long a mute chosen in the mute dialog lasts.
enum MuteDuration {
  oneHour(Duration(hours: 1)),
  eightHours(Duration(hours: 8)),
  oneWeek(Duration(days: 7)),

  /// Until the user turns it off again (`until: null` on the wire).
  forever(null);

  const MuteDuration(this.duration);
  final Duration? duration;

  /// The wire value for [mode] chosen now. "Off" never carries an until:
  /// the server deletes the mute row for it anyway.
  MuteSetting settingFor(MuteMode mode, DateTime now) => MuteSetting(
    mode: mode,
    until: mode == MuteMode.off || duration == null
        ? null
        : now.toUtc().add(duration!),
  );
}

/// In-memory cache of this device's conversation mutes (spec D6).
///
/// WHY in memory and not a drift table: mutes live on the server per device
/// (the server is what skips the push), `GET /mutes` is one small request,
/// and the list only needs icons and the badge filter. A persisted copy would
/// add a schema migration on web and iOS just to show an icon a second
/// earlier on cold start, and could drift from the server truth.
///
/// Keys are lower-cased conversation ids: a group id, or for a 1:1 the
/// peer's identity id. That is the same id the app files a direct
/// conversation under (the sender's IDENTITY, i.e. its primary device), and
/// `GET /mutes` reports the peer's PRIMARY device, so the two line up without
/// any mapping table.
class MuteController extends ChangeNotifier {
  MuteController({required ApiClient apiClient, DateTime Function()? clock})
    : _api = apiClient,
      _clock = clock ?? DateTime.now;

  final ApiClient _api;
  final DateTime Function() _clock;
  final Map<String, MuteSetting> _mutes = {};
  Timer? _expiryTimer;
  bool _disposed = false;

  /// Replaces the cache with the server's list. Failures propagate so the
  /// caller decides; the previous cache stays (stale icons beat no icons).
  Future<void> load() async {
    final entries = await _api.getMutes();
    if (_disposed) return;
    _mutes
      ..clear()
      ..addEntries([
        for (final e in entries)
          if ((e.groupId ?? e.peerDeviceId) != null)
            MapEntry((e.groupId ?? e.peerDeviceId)!.toLowerCase(), e.setting),
      ]);
    _changed();
  }

  /// The stored setting (possibly expired) of [conversationId].
  MuteSetting settingOf(String conversationId) =>
      _mutes[conversationId.toLowerCase()] ?? MuteSetting.off;

  /// The mode in force right now: an expired `until` reads as off, the same
  /// rule the server applies before skipping a push.
  MuteMode modeOf(String conversationId) =>
      settingOf(conversationId).effectiveMode(_clock());

  bool isMuted(String conversationId) => modeOf(conversationId) != MuteMode.off;

  /// Updates the cache from `myMute` of `GET /groups/{id}` (fresher than the
  /// list when a group screen re-reads the group).
  void applyGroupMute(String groupId, MuteSetting setting) {
    _put(groupId, setting);
    _changed();
  }

  /// Stores [setting] on the server, then in the cache. Throws on failure
  /// and leaves the cache untouched, so the icon never claims a mute the
  /// server does not know about (pushes would keep coming).
  Future<void> setMute({
    required String conversationId,
    required bool group,
    required MuteSetting setting,
  }) async {
    if (group) {
      await _api.setGroupMute(conversationId, setting);
    } else {
      await _api.setDirectMute(conversationId, setting);
    }
    if (_disposed) return;
    _put(conversationId, setting);
    _changed();
  }

  /// Sum of unread messages over conversations that are not muted: the
  /// number for the app's "Chats" badge (spec D6, muted chats do not count).
  ///
  /// WHY "bots only" also drops out: the unread counter is per conversation,
  /// not per sender kind, so it cannot tell a bot message from a human one.
  /// Muting bots is chosen for chats whose traffic is mostly bot chatter;
  /// counting them would bring back exactly the noise the user turned off.
  int unreadTotal(Iterable<Conversation> conversations) => conversations
      .where((c) => !isMuted(c.id))
      .fold(0, (sum, c) => sum + c.unreadCount);

  void _put(String conversationId, MuteSetting setting) {
    final key = conversationId.toLowerCase();
    if (setting.mode == MuteMode.off) {
      _mutes.remove(key);
    } else {
      _mutes[key] = setting;
    }
  }

  void _changed() {
    _scheduleExpiry();
    notifyListeners();
  }

  /// One timer for the next `until`: when a mute runs out the icons and the
  /// badge must update without the user touching anything. One timer, not
  /// polling: it is re-armed on every change.
  void _scheduleExpiry() {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    final now = _clock();
    DateTime? next;
    for (final s in _mutes.values) {
      final until = s.until;
      if (until == null || !until.isAfter(now)) continue;
      if (next == null || until.isBefore(next)) next = until;
    }
    if (next == null) return;
    _expiryTimer = Timer(next.difference(now), () {
      if (!_disposed) _changed();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _expiryTimer?.cancel();
    super.dispose();
  }
}
