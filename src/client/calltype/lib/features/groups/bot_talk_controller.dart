import 'dart:async';

import 'package:calltype_core/network/group_dtos.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'package:calltype_core/network/api_client.dart';

/// Why saving the bot conversation setting failed. The screen maps it to a
/// localized message (controllers have no BuildContext, see lib/l10n).
enum BotTalkError {
  /// 403: this device is not an admin of the group (or a companion device,
  /// which is never a member and so is never an admin).
  forbidden,

  /// 400 `not_a_bot_member`: a checked bot left the group meanwhile.
  notABotMember,

  /// Any other 400 (`invalid_mode`, number out of range): the form already
  /// checks the ranges, so this means the server's rules changed.
  invalid,

  /// Network failure, 5xx, anything unexpected.
  failed,
}

/// State of the group "Bot conversation" section (design doc "Client UI").
///
/// Holds both the server value and the user's draft so a `GroupChanged` hint
/// (another admin saved) can refresh the screen without throwing away what
/// this user is typing.
class BotTalkController extends ChangeNotifier {
  BotTalkController({
    required ApiClient apiClient,
    required this.groupId,
    required String selfDeviceId,
    Stream<Map<String, dynamic>>? groupChanged,
  }) : _api = apiClient,
       _self = selfDeviceId.toLowerCase() {
    // The hub hint carries no data; it only says "re-read this group".
    _hint = groupChanged?.listen((payload) {
      final id = payload['groupId'];
      if (id is String && id.toLowerCase() == groupId.toLowerCase()) {
        unawaited(load().catchError((Object _) {}));
      }
    });
  }

  static const minTurns = 1;
  static const maxTurns = 50;
  static const minPause = 0;
  static const maxPause = 1440;

  final ApiClient _api;
  final String groupId;
  final String _self;
  StreamSubscription<Map<String, dynamic>>? _hint;
  bool _disposed = false;

  bool loading = true;
  bool loadFailed = false;
  bool saving = false;

  /// Only admins of the group may change the setting. Determined from THIS
  /// device's row in the member list: a companion device is not a member at
  /// all (it acts for its primary) and the server answers it 403, so it is
  /// read-only here too instead of offering a Save that always fails.
  bool canEdit = false;

  /// Bot members, without the business auditor: the auditor is a silent
  /// archiver and never a bot-talk participant (design doc).
  List<GroupMemberInfo> bots = const [];

  /// The setting as the server last reported it.
  BotTalkSettings saved = BotTalkSettings.off;

  // -- Draft --------------------------------------------------------------
  BotTalkMode mode = BotTalkMode.off;
  final Set<String> selected = {};
  String maxTurnsText = '${BotTalkSettings.defaultMaxBotTurns}';
  String pauseText = '${BotTalkSettings.defaultPauseMinutes}';

  /// Bumped whenever the draft is replaced from the server, so the screen
  /// knows to refill its text fields (it owns the TextEditingControllers).
  int draftVersion = 0;
  bool _dirty = false;

  Future<void> load() async {
    try {
      final results = await Future.wait([
        _api.getGroup(groupId),
        _api.getGroupMemberInfos(groupId),
      ]);
      if (_disposed) return;
      final details = results[0] as GroupDetails;
      final members = results[1] as List<GroupMemberInfo>;
      saved = details.botTalk;
      canEdit = members.any(
        (m) => m.deviceId.toLowerCase() == _self && m.role == 'admin',
      );
      bots = [
        for (final m in members)
          if (m.isBot && m.role != 'auditor') m,
      ];
      loadFailed = false;
      // Another admin's change must not wipe what this user is typing.
      if (!_dirty) _resetDraft();
    } catch (_) {
      if (_disposed) return;
      loadFailed = true;
    }
    loading = false;
    notifyListeners();
  }

  void setMode(BotTalkMode value) {
    if (!canEdit) return;
    mode = value;
    _dirty = true;
    notifyListeners();
  }

  void toggleBot(String deviceId, bool on) {
    if (!canEdit) return;
    final id = deviceId.toLowerCase();
    if (on) {
      selected.add(id);
    } else {
      selected.remove(id);
    }
    _dirty = true;
    notifyListeners();
  }

  bool isSelected(String deviceId) => selected.contains(deviceId.toLowerCase());

  void setMaxTurnsText(String value) {
    maxTurnsText = value;
    _dirty = true;
    notifyListeners();
  }

  void setPauseText(String value) {
    pauseText = value;
    _dirty = true;
    notifyListeners();
  }

  /// Whole number in [min]..[max], else null. Shared by the field
  /// validators and [save], so the form and the request agree.
  static int? parseInRange(String text, int min, int max) {
    final value = int.tryParse(text.trim());
    if (value == null || value < min || value > max) return null;
    return value;
  }

  bool get maxTurnsValid =>
      parseInRange(maxTurnsText, minTurns, maxTurns) != null;
  bool get pauseValid => parseInRange(pauseText, minPause, maxPause) != null;

  /// Saves the draft. Returns null on success, else why it failed. Does not
  /// call the server when the form is invalid (the fields show why).
  Future<BotTalkError?> save() async {
    final turns = parseInRange(maxTurnsText, minTurns, maxTurns);
    final pause = parseInRange(pauseText, minPause, maxPause);
    if (!canEdit || turns == null || pause == null) return BotTalkError.invalid;
    saving = true;
    notifyListeners();
    try {
      final result = await _api.setGroupBotTalk(
        groupId,
        BotTalkSettings(
          mode: mode,
          // Only "selected" uses the list. Sending it in the other modes
          // would let a bot that has left the group meanwhile turn a harmless
          // "all"/"off" save into a 400 not_a_bot_member. Filtered to the
          // current bots for the same reason.
          allowedBotDeviceIds: mode == BotTalkMode.selected
              ? [
                  for (final b in bots)
                    if (isSelected(b.deviceId)) b.deviceId,
                ]
              : const [],
          maxBotTurns: turns,
          pauseMinutes: pause,
        ),
      );
      if (_disposed) return null;
      saved = result;
      _dirty = false;
      _resetDraft();
      return null;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 403) {
        // The server is the authority: if it says no, stop offering edits.
        canEdit = false;
        return BotTalkError.forbidden;
      }
      if (status == 400) {
        final data = e.response?.data;
        final code = data is Map ? data['error'] : null;
        return code == 'not_a_bot_member'
            ? BotTalkError.notABotMember
            : BotTalkError.invalid;
      }
      return BotTalkError.failed;
    } catch (_) {
      return BotTalkError.failed;
    } finally {
      saving = false;
      if (!_disposed) notifyListeners();
    }
  }

  void _resetDraft() {
    mode = saved.mode;
    selected
      ..clear()
      ..addAll(saved.allowedBotDeviceIds.map((id) => id.toLowerCase()));
    maxTurnsText = '${saved.maxBotTurns}';
    pauseText = '${saved.pauseMinutes}';
    draftVersion++;
  }

  @override
  void dispose() {
    _disposed = true;
    _hint?.cancel();
    super.dispose();
  }
}
