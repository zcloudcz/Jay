import 'dart:typed_data';

import 'package:calltype/features/devices/device_service.dart';
import 'package:calltype/features/notifications/notification_directory.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_multi_device_server.dart';
import '../../helpers/test_device.dart';
import '../channels/fake_channels.dart';

/// Spec 2026-11-11-bot-ack-reactions N3: a bot that is no contact (met in a
/// group) is still recognised as a bot, through its server profile.
void main() {
  late TestDevice device;
  late FakeMultiDeviceServer server;
  late DeviceService devices;
  late ChannelHarness channels;
  late List<String> lookups;
  late Map<String, Object> answers;

  setUp(() async {
    device = await TestDevice.create('me');
    server = FakeMultiDeviceServer();
    devices = DeviceService(
      database: device.db,
      apiClient: FakeDeviceApi(server),
      keyManager: device.keys,
      sessionManager: device.sessions,
      signalRClient: FakeHubClient(server, 'me'),
    );
    channels = ChannelHarness();
    lookups = [];
    answers = {};
  });

  tearDown(() async {
    devices.dispose();
    await device.db.close();
  });

  AppNotificationDirectory directory() => AppNotificationDirectory(
    database: device.db,
    devices: devices,
    channels: channels.controller,
    remoteIsBot: (id) async {
      lookups.add(id);
      final answer = answers[id];
      if (answer is Exception) throw answer;
      return answer == true;
    },
  );

  test('a contact answers from the database, without a lookup', () async {
    await device.db
        .into(device.db.contacts)
        .insert(
          ContactsCompanion.insert(
            deviceId: 'botty',
            userHandle: 'CT-BOTT-0001',
            identityKey: Uint8List(0),
            addedAt: DateTime.utc(2026, 11, 12),
            isBot: const Value(true),
          ),
        );
    final contact = await directory().contact('botty');
    expect(contact.isBot, isTrue);
    expect(contact.name, 'CT-BOTT-0001');
    expect(lookups, isEmpty);
  });

  test('no contact: the server profile decides, asked once', () async {
    answers['groupbot'] = true;
    final d = directory();
    expect((await d.contact('groupbot')).isBot, isTrue);
    expect((await d.contact('GROUPBOT')).isBot, isTrue);
    expect((await d.contact('stranger')).isBot, isFalse);
    expect(lookups, ['groupbot', 'stranger']);
  });

  test('a failed lookup counts as no bot and is asked again', () async {
    answers['groupbot'] = Exception('offline');
    final d = directory();
    expect((await d.contact('groupbot')).isBot, isFalse);
    answers['groupbot'] = true;
    expect((await d.contact('groupbot')).isBot, isTrue);
    expect(lookups, ['groupbot', 'groupbot']);
  });
}
