import 'database.dart';

/// True when [deviceId] is in `BlockedDevices` (G §4.3 point 3, K8).
///
/// A plain function over the database instead of `PeerDirectory` because
/// its callers have no widget tree: the notification background isolate
/// (N) and the inbox, which checks it inside its transaction. The app's
/// `PeerDirectory.isBlocked` must give the same answer — both read the one
/// table, never `Contacts` (blocking survives deleting the contact).
Future<bool> isDeviceBlocked(AppDatabase db, String deviceId) async {
  final row = await (db.select(
    db.blockedDevices,
  )..where((b) => b.deviceId.equals(deviceId))).getSingleOrNull();
  return row != null;
}
