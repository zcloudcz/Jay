import 'package:drift/drift.dart';

import '../storage/database.dart';

/// Who is "the person" behind a device id, and which devices a direct
/// message has to reach (D §4.1 point 2).
///
/// WHY an interface already in wave 1, while every person still has exactly
/// one device: streams M, C and G write new code that addresses people, and
/// they write it against this seam now so multi-device (stream D, wave 2)
/// only swaps the implementation ([SingleDeviceDirectory] →
/// `AccountDeviceDirectory`) instead of touching every sender again.
abstract interface class DeviceDirectory {
  /// Devices of the peer of the direct conversation [conversationId]
  /// (including the anchor device). Never empty.
  Future<List<String>> peerDevices(String conversationId);

  /// All devices of the person [deviceId] belongs to (including it). For
  /// receipts and calls.
  Future<List<String>> devicesOfPeer(String deviceId);

  /// My OTHER active devices (not this one). Wave 1: always empty.
  Future<List<String>> ownOtherDevices();

  /// Local id of the direct conversation for an incoming message from
  /// [senderDeviceId]. Wave 1: the sender id itself.
  Future<String> directConversationFor(String senderDeviceId);

  /// True when a message from [deviceId] is "mine": this device, or any of
  /// my own devices, active or historical.
  Future<bool> isOwnDevice(String deviceId);

  /// True only for my ACTIVE own devices — `sync` is accepted only from
  /// these.
  Future<bool> isActiveOwnDevice(String deviceId);

  /// Fires when the answer to any question above may have changed.
  Stream<void> get changes;
}

/// Splits one outgoing direct plaintext into one plaintext per device.
abstract interface class DirectPayloadPlanner {
  /// deviceId → plaintext JSON to encrypt for that device. Wave 1:
  /// `{conversationId: payloadJson}`, and an EMPTY map when
  /// [ownDevicesOnly] is true (there are no other own devices yet).
  Future<Map<String, String>> plan(
    String conversationId,
    String payloadJson, {
    bool ownDevicesOnly = false,
  });
}

/// Reserved `ContactDevices.contactId` for my own devices (D §4.1).
const selfContactId = 'self';

/// Wave-1 directory: a contact IS one device, and so am I.
///
/// It still consults `ContactDevices(contactId: 'self')` for "is this my
/// device" so a database restored from a multi-device backup (wave 2) keeps
/// showing my old messages as mine even after a downgrade to this class.
class SingleDeviceDirectory implements DeviceDirectory, DirectPayloadPlanner {
  /// [myDeviceId] is a getter, not a value: the app creates its services
  /// before onboarding has registered the device, and the id only exists
  /// afterwards (same reason `SignalRClient.setDeviceId` exists).
  SingleDeviceDirectory({
    required AppDatabase database,
    required String Function() myDeviceId,
  }) : _db = database,
       _myDeviceId = myDeviceId;

  final AppDatabase _db;
  final String Function() _myDeviceId;

  @override
  Future<List<String>> peerDevices(String conversationId) async => [
    conversationId,
  ];

  @override
  Future<List<String>> devicesOfPeer(String deviceId) async => [deviceId];

  @override
  Future<List<String>> ownOtherDevices() async => const [];

  @override
  Future<String> directConversationFor(String senderDeviceId) async =>
      senderDeviceId;

  @override
  Future<bool> isOwnDevice(String deviceId) async {
    if (deviceId == _myDeviceId()) return true;
    return await _selfRow(deviceId) != null;
  }

  @override
  Future<bool> isActiveOwnDevice(String deviceId) async {
    if (deviceId == _myDeviceId()) return true;
    final row = await _selfRow(deviceId);
    return row != null && row.removedAt == null;
  }

  // Nothing in wave 1 changes the answers above at runtime.
  @override
  Stream<void> get changes => const Stream<void>.empty();

  @override
  Future<Map<String, String>> plan(
    String conversationId,
    String payloadJson, {
    bool ownDevicesOnly = false,
  }) async => ownDevicesOnly ? const {} : {conversationId: payloadJson};

  Future<ContactDevice?> _selfRow(String deviceId) =>
      (_db.select(_db.contactDevices)..where(
            (d) =>
                d.deviceId.equals(deviceId) & d.contactId.equals(selfContactId),
          ))
          .getSingleOrNull();
}
