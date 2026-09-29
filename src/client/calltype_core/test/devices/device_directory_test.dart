import 'package:calltype_core/devices/device_directory.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:test/test.dart';

void main() {
  late AppDatabase db;
  late SingleDeviceDirectory directory;
  var me = 'me';

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    me = 'me';
    directory = SingleDeviceDirectory(database: db, myDeviceId: () => me);
  });
  tearDown(() => db.close());

  test('a contact is exactly one device', () async {
    expect(await directory.peerDevices('bob'), ['bob']);
    expect(await directory.devicesOfPeer('bob'), ['bob']);
    expect(await directory.directConversationFor('bob'), 'bob');
    expect(await directory.ownOtherDevices(), isEmpty);
  });

  test('plan fans out to the conversation device only', () async {
    expect(await directory.plan('bob', '{"v":1}'), {'bob': '{"v":1}'});
    expect(
      await directory.plan('bob', '{"v":1}', ownDevicesOnly: true),
      isEmpty,
    );
  });

  test('own device: this one, plus self rows of ContactDevices', () async {
    expect(await directory.isOwnDevice('me'), isTrue);
    expect(await directory.isOwnDevice('bob'), isFalse);
    // The id is read lazily (onboarding registers after construction).
    me = 'me-later';
    expect(await directory.isOwnDevice('me-later'), isTrue);

    await db
        .into(db.contactDevices)
        .insert(
          ContactDevicesCompanion.insert(
            deviceId: 'old-phone',
            contactId: selfContactId,
            addedAt: DateTime.utc(2026),
            removedAt: Value(DateTime.utc(2026, 6)),
          ),
        );
    await db
        .into(db.contactDevices)
        .insert(
          ContactDevicesCompanion.insert(
            deviceId: 'bob-laptop',
            contactId: 'bob',
            addedAt: DateTime.utc(2026),
          ),
        );
    expect(await directory.isOwnDevice('old-phone'), isTrue);
    expect(await directory.isActiveOwnDevice('old-phone'), isFalse);
    expect(await directory.isOwnDevice('bob-laptop'), isFalse);
    expect(await directory.isActiveOwnDevice('me-later'), isTrue);
  });
}
