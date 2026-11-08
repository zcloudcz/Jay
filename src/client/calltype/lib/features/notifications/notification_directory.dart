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
  }) : _db = database,
       _devices = devices,
       _channels = channels;

  final AppDatabase _db;
  final DeviceService _devices;
  final ChannelsController _channels;

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
      isBot: row?.isBot ?? false,
    );
  }

  @override
  Future<String> identityOfDevice(String deviceId) async => _devices.isOpen
      ? await _devices.directory.identityOf(deviceId)
      : deviceId.toLowerCase();

  @override
  String? channelName(String channelId) => _channels.channel(channelId)?.name;
}
