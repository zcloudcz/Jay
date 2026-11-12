import 'package:calltype_core/storage/database.dart';
import '../channels/channels_controller.dart';
import '../devices/device_service.dart';
import 'notification_service.dart';

/// [NotificationDirectory] over the app's database and controllers. Names
/// follow the chat list exactly (conversation title, else the contact's
/// display name, else its handle), so a notification never names a chat
/// differently than the list does.
class AppNotificationDirectory implements NotificationDirectory {
  AppNotificationDirectory({
    required AppDatabase database,
    required DeviceService devices,
    required ChannelsController channels,
    Future<bool> Function(String identityId)? remoteIsBot,
  }) : _db = database,
       _devices = devices,
       _channels = channels,
       _remoteIsBot = remoteIsBot;

  final AppDatabase _db;
  final DeviceService _devices;
  final ChannelsController _channels;

  /// The server's `isBot` for an identity that is not a contact (e.g. a bot
  /// met in a group), so its reactions stay quiet too (spec
  /// 2026-11-11-bot-ack-reactions N3). Asked once per identity and run; a
  /// failed lookup counts as "not a bot" and is asked again next time.
  final Future<bool> Function(String identityId)? _remoteIsBot;
  final _remoteBots = <String, Future<bool>>{};

  @override
  String? get selfIdentityId =>
      _devices.isOpen ? _devices.directory.selfIdentityId : null;

  @override
  Future<({bool group, String? title})> conversation(
    String conversationId,
  ) async {
    final row = await (_db.select(
      _db.conversations,
    )..where((c) => c.id.equals(conversationId))).getSingleOrNull();
    final group = row?.type == 'group';
    if (row?.title != null) return (group: group, title: row!.title);
    if (group) return (group: true, title: null);
    return (group: false, title: (await contact(conversationId)).name);
  }

  @override
  Future<({String? name, bool isBot})> contact(String identityId) async {
    final row = await (_db.select(
      _db.contacts,
    )..where((c) => c.deviceId.equals(identityId))).getSingleOrNull();
    return (
      name: row?.displayName ?? row?.userHandle,
      isBot: row?.isBot ?? await _remoteBot(identityId),
    );
  }

  Future<bool> _remoteBot(String identityId) async {
    final lookup = _remoteIsBot;
    if (lookup == null) return false;
    final key = identityId.toLowerCase();
    try {
      return await (_remoteBots[key] ??= lookup(
        identityId,
      ).timeout(const Duration(seconds: 5)));
    } catch (_) {
      _remoteBots.remove(key);
      return false;
    }
  }

  @override
  Future<String> identityOfDevice(String deviceId) async => _devices.isOpen
      ? await _devices.directory.identityOf(deviceId)
      : deviceId.toLowerCase();

  @override
  String? channelName(String channelId) => _channels.channel(channelId)?.name;
}
