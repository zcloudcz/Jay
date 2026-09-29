import 'package:calltype_core/storage/block_list.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:test/test.dart';

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('reads BlockedDevices, independent of Contacts', () async {
    expect(await isDeviceBlocked(db, 'eve'), isFalse);
    await db
        .into(db.blockedDevices)
        .insert(
          BlockedDevicesCompanion.insert(
            deviceId: 'eve',
            blockedAt: DateTime.utc(2026, 9, 29),
            userHandle: const Value('CT-EVE0-0001'),
          ),
        );
    // Eve is not (and never was) a contact — blocking a stranger works.
    expect(await db.select(db.contacts).get(), isEmpty);
    expect(await isDeviceBlocked(db, 'eve'), isTrue);
    expect(await isDeviceBlocked(db, 'bob'), isFalse);
  });
}
