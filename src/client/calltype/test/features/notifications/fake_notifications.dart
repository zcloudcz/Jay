import 'dart:async';

import 'package:calltype_core/network/api_client.dart';
import 'package:calltype/core/network/push_service.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:calltype/features/notifications/local_notifier.dart';
import 'package:calltype/features/notifications/notification_content.dart';
import 'package:calltype/features/notifications/notification_service.dart';
import 'package:calltype_core/network/channel_dtos.dart';
import 'package:calltype_core/network/group_dtos.dart' show MuteMode;

import '../../helpers/localized_app.dart';

/// Test doubles for every platform piece of notifications: none of the real
/// plugins (flutter_local_notifications, firebase, the browser, the APNs
/// channel) exists under `flutter test`.
class FakeNotifier implements LocalNotifier {
  FakeNotifier({
    this.current = NotifierPermission.granted,
    this.answer = NotifierPermission.granted,
    this.needsGesture = false,
  });

  NotifierPermission current;
  NotifierPermission answer;
  bool needsGesture;
  bool failInitialize = false;
  int prompts = 0;
  NotificationChannelNames? names;
  final shown = <LocalNotification>[];
  final cancelled = <NotificationTarget>[];
  final tapController = StreamController<Map<String, String>>.broadcast();
  Map<String, String>? launch;

  @override
  Future<void> initialize(NotificationChannelNames names) async {
    if (failInitialize) throw StateError('no plugin');
    this.names = names;
  }

  @override
  Future<NotifierPermission> permission() async => current;

  @override
  Future<NotifierPermission> requestPermission() async {
    prompts++;
    return current = answer;
  }

  @override
  bool get permissionNeedsUserGesture => needsGesture;

  @override
  Future<void> show(LocalNotification notification) async =>
      shown.add(notification);

  @override
  Future<void> cancel(NotificationTarget target) async => cancelled.add(target);

  @override
  Stream<Map<String, String>> get taps => tapController.stream;

  @override
  Future<Map<String, String>?> takeLaunchTap() async {
    final value = launch;
    launch = null;
    return value;
  }
}

class MemoryPrefs implements NotificationPrefsStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

class FakeDirectory implements NotificationDirectory {
  @override
  String? selfIdentityId = 'me';
  final groups = <String, String?>{};
  final contacts = <String, ({String? name, bool isBot})>{};
  final channels = <String, String>{};
  final devices = <String, String>{};

  @override
  Future<({bool group, String? title})> conversation(String id) async {
    if (groups.containsKey(id)) return (group: true, title: groups[id]);
    return (group: false, title: contacts[id]?.name);
  }

  @override
  Future<({String? name, bool isBot})> contact(String identityId) async =>
      contacts[identityId] ?? (name: null, isBot: false);

  @override
  Future<String> identityOfDevice(String deviceId) async =>
      devices[deviceId] ?? deviceId;

  @override
  String? channelName(String channelId) => channels[channelId];
}

/// Records the push-token traffic of contract 1.1.
class FakePushApi extends ApiClient {
  FakePushApi() : super(baseUrl: 'http://unused');
  final calls = <String>[];

  @override
  Future<void> updatePushToken({
    required String deviceId,
    required String token,
    required String platform,
    String? locale,
    bool ringCalls = false,
  }) async => calls.add(
    'PUT $deviceId $platform $token $locale${ringCalls ? ' ring' : ''}',
  );

  @override
  Future<void> deletePushToken(String deviceId) async =>
      calls.add('DELETE $deviceId');

  @override
  Future<void> updateVoipToken({
    required String deviceId,
    required String token,
  }) async => calls.add('PUT-VOIP $deviceId $token');

  @override
  Future<void> deleteVoipToken(String deviceId) async =>
      calls.add('DELETE-VOIP $deviceId');
}

class FakePushProvider implements PushProvider {
  FakePushProvider({this.platform = 'fcm'});
  @override
  final String platform;
  PushStatus? unavailable;
  String token = 'tok';
  bool released = false;
  final openedController = StreamController<Map<String, String>>.broadcast();

  @override
  Future<String> obtainToken() async {
    final status = unavailable;
    if (status != null) throw PushUnavailable(status);
    return token;
  }

  @override
  Stream<String> get tokenRefresh => const Stream.empty();
  @override
  Stream<Map<String, String>> get opened => openedController.stream;
  @override
  Future<Map<String, String>?> takeInitialOpened() async => null;
  @override
  Stream<Map<String, String>> get foreground => const Stream.empty();
  @override
  Future<void> release() async => released = true;
}

/// A [NotificationService] wired to fakes, with knobs for focus, route and
/// mutes.
class NotificationHarness {
  NotificationHarness({
    FakeNotifier? notifier,
    this.provider,
    String? deviceId = 'dev-1',
  }) : notifier = notifier ?? FakeNotifier() {
    service = NotificationService(
      notifier: this.notifier,
      prefs: prefs,
      strings: () => l10nEn,
      directory: directory,
      currentPath: () => path,
      appFocused: () => focused,
      openRoute: routes.add,
      muteOf: (id) => mutes[id] ?? MuteMode.off,
      apiClient: api,
      pushProvider: provider,
      deviceId: () => deviceId,
      locale: () => 'cs',
    );
  }

  final FakeNotifier notifier;
  final FakePushProvider? provider;
  final prefs = MemoryPrefs();
  final directory = FakeDirectory();
  final api = FakePushApi();
  final routes = <String>[];
  final mutes = <String, MuteMode>{};
  String? path = '/chats';
  bool focused = true;
  late final NotificationService service;
}

Message message({
  String id = 'm1',
  String conversationId = 'alice',
  String senderId = 'alice',
  String? body = 'Hello',
  String type = 'text',
  bool deleted = false,
}) => Message(
  id: id,
  conversationId: conversationId,
  senderId: senderId,
  body: body,
  type: type,
  status: 'delivered',
  createdAt: DateTime.utc(2026, 11, 6),
  forwarded: false,
  deleted: deleted,
);

ChannelPostDto channelPost({
  String channelId = 'c1',
  String kind = 'text',
  String body = 'Big news',
}) => ChannelPostDto(
  channelId: channelId,
  postId: 'p1',
  kind: kind,
  body: body,
  createdAt: DateTime.utc(2026, 11, 6),
);
