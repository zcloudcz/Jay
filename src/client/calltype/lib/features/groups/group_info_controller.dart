import 'dart:async';

import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:dio/dio.dart';
import 'package:calltype_core/network/group_dtos.dart';
import 'package:flutter/foundation.dart';

import 'group_topic_service.dart';
import 'group_topic_store.dart';

/// Why changing a member's role failed (spec 2026-11-13-group-topics S1).
enum GroupRoleError {
  /// 409 `last_admin`: the group would be left without an admin.
  lastAdmin,

  /// 400 `bot_cannot_be_admin`.
  bot,

  /// 403: this device is not an admin (any more).
  notAdmin,

  /// 404 from an old server without the role endpoint.
  unsupported,

  /// Network failure, 5xx, anything unexpected.
  failed,
}

/// State of the Group info screen (spec row 12/13): name and topic from the
/// local database, members and roles from the server.
///
/// Members are re-read after every role change and on each `GroupChanged`
/// hint (another admin promoted somebody, a topic was recorded), like the
/// bot-talk screen does.
class GroupInfoController extends ChangeNotifier {
  GroupInfoController({
    required AppDatabase database,
    required ApiClient apiClient,
    required this.groupId,
    required String selfDeviceId,
    required String selfIdentityId,
    GroupTopicService? topics,
    Stream<Map<String, dynamic>>? groupChanged,
  }) : _db = database,
       _api = apiClient,
       _topics = topics,
       _self = selfDeviceId.toLowerCase(),
       selfIdentityId = selfIdentityId.toLowerCase() {
    _hint = groupChanged?.listen((payload) {
      final id = payload['groupId'];
      if (id is String && id.toLowerCase() == groupId.toLowerCase()) {
        unawaited(load());
      }
    });
    // Drift watches: the topic changes when the inbox applies a new one,
    // the name with the next group message.
    _topicSub = watchGroupTopic(_db, groupId).listen((t) {
      topic = t;
      if (!_disposed) notifyListeners();
    });
    _conversationSub =
        (_db.select(
          _db.conversations,
        )..where((c) => c.id.equals(groupId))).watchSingleOrNull().listen((c) {
          conversation = c;
          if (!_disposed) notifyListeners();
        });
  }

  final AppDatabase _db;
  final ApiClient _api;
  final GroupTopicService? _topics;
  final String groupId;

  /// THIS device: admin rights belong to member rows, a companion has none.
  final String _self;

  /// "Me" in the member list (a companion's identity is its primary).
  final String selfIdentityId;
  StreamSubscription<Map<String, dynamic>>? _hint;
  StreamSubscription<StoredGroupTopic?>? _topicSub;
  StreamSubscription<Conversation?>? _conversationSub;
  bool _disposed = false;

  bool loading = true;
  bool loadFailed = false;

  /// A role change or topic save is in flight.
  bool busy = false;

  List<GroupMemberInfo> members = const [];
  StoredGroupTopic? topic;
  Conversation? conversation;

  /// Known from the server's group record (organizationId) or the local
  /// row: no topics and no T6 in business groups (spec row 11).
  bool _serverBusiness = false;
  bool get business => _serverBusiness || conversation?.organizationId != null;

  bool get isAdmin => members.any(
    (m) => m.deviceId.toLowerCase() == _self && m.role == 'admin',
  );

  /// Admin actions on topics: only for an admin, outside business groups,
  /// and only when the app can send it (the service is app-wide).
  bool get canEditTopic => isAdmin && !business && _topics != null;

  int get _adminCount => members.where((m) => m.role == 'admin').length;

  bool isSelf(GroupMemberInfo m) =>
      m.deviceId.toLowerCase() == selfIdentityId ||
      m.deviceId.toLowerCase() == _self;

  /// "Make admin" (spec row 13): only an admin sees it, never for bots or
  /// the auditor, and not for somebody who is admin already.
  bool canMakeAdmin(GroupMemberInfo m) =>
      isAdmin && !m.isBot && m.role == 'member';

  /// "Remove admin": hidden when the target is the only admin (the server
  /// would answer 409 `last_admin` anyway).
  bool canRemoveAdmin(GroupMemberInfo m) =>
      isAdmin && m.role == 'admin' && _adminCount > 1;

  Future<void> load() async {
    try {
      final results = await Future.wait([
        _api.getGroup(groupId),
        _api.getGroupMemberInfos(groupId),
      ]);
      if (_disposed) return;
      final details = results[0] as GroupDetails;
      _serverBusiness = details.raw['organizationId'] != null;
      members = _sorted(results[1] as List<GroupMemberInfo>);
      loadFailed = false;
    } catch (_) {
      if (_disposed) return;
      loadFailed = true;
    }
    loading = false;
    notifyListeners();
  }

  /// Admins first, then people, then bots, the auditor last; by name inside.
  List<GroupMemberInfo> _sorted(List<GroupMemberInfo> list) {
    int rank(GroupMemberInfo m) => m.role == 'admin'
        ? 0
        : m.role == 'auditor'
        ? 3
        : m.isBot
        ? 2
        : 1;
    String name(GroupMemberInfo m) =>
        (m.displayName ?? m.userHandle ?? m.deviceId).toLowerCase();
    return [...list]..sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : name(a).compareTo(name(b));
    });
  }

  /// Promotes ([admin] true) or demotes [member]. Returns null on success.
  /// The list is reloaded from the server afterwards either way, so it never
  /// shows a role the server does not have.
  Future<GroupRoleError?> setRole(GroupMemberInfo member, bool admin) async {
    busy = true;
    notifyListeners();
    GroupRoleError? error;
    try {
      await _api.setGroupMemberRole(
        groupId,
        member.deviceId,
        admin ? 'admin' : 'member',
      );
    } on DioException catch (e) {
      final data = e.response?.data;
      final code = data is Map ? (data['code'] ?? data['error']) : null;
      error = switch (e.response?.statusCode) {
        409 when code == 'last_admin' => GroupRoleError.lastAdmin,
        400 when code == 'bot_cannot_be_admin' => GroupRoleError.bot,
        403 => GroupRoleError.notAdmin,
        // 404 `not_a_member` is a member that left meanwhile (the reload
        // shows it); a bare 404 is a server without this endpoint.
        404 when code == 'not_a_member' => GroupRoleError.failed,
        404 => GroupRoleError.unsupported,
        _ => GroupRoleError.failed,
      };
    } catch (_) {
      error = GroupRoleError.failed;
    }
    if (_disposed) return error;
    await load();
    busy = false;
    if (!_disposed) notifyListeners();
    return error;
  }

  /// Sets the topic through [GroupTopicService] (spec row 14).
  Future<GroupTopicResult> setTopic(String text) async {
    final service = _topics;
    if (service == null) {
      return const GroupTopicResult.failed(GroupTopicError.failed);
    }
    busy = true;
    notifyListeners();
    try {
      return await service.setTopic(groupId, text);
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _hint?.cancel();
    _topicSub?.cancel();
    _conversationSub?.cancel();
    super.dispose();
  }
}
