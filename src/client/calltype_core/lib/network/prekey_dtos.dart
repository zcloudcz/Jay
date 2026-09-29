/// Pre-key maintenance DTOs (S §4.2, frozen in contracts §2.2). JSON field
/// names live here only, like channel_dtos.dart. Stream S (S3/S4) builds the
/// replenishment and rotation logic on top of them.
library;

/// `GET /devices/{id}/prekeys` → 200.
class PreKeyStatus {
  const PreKeyStatus({
    required this.oneTimePreKeyCount,
    required this.oneTimePreKeyIds,
    required this.maxOneTimePreKeys,
    required this.signedPreKeyId,
    this.signedPreKeyUpdatedAt,
  });

  factory PreKeyStatus.fromJson(Map<String, dynamic> json) => PreKeyStatus(
    oneTimePreKeyCount: json['oneTimePreKeyCount'] as int,
    // The ids (not just a count) let the client see which of its local keys
    // were consumed and may be erased.
    oneTimePreKeyIds: (json['oneTimePreKeyIds'] as List).cast<int>(),
    maxOneTimePreKeys: json['maxOneTimePreKeys'] as int,
    signedPreKeyId: json['signedPreKeyId'] as int,
    signedPreKeyUpdatedAt: json['signedPreKeyUpdatedAt'] == null
        ? null
        : DateTime.parse(json['signedPreKeyUpdatedAt'] as String).toUtc(),
  );

  final int oneTimePreKeyCount;
  final List<int> oneTimePreKeyIds;
  final int maxOneTimePreKeys;
  final int signedPreKeyId;

  /// Null until the device rotated its signed pre-key for the first time.
  final DateTime? signedPreKeyUpdatedAt;
}

/// `POST /devices/{id}/prekeys` → 200. Re-sending already stored
/// `(keyId, publicKey)` pairs is a no-op (`stored: 0`), so uploads are
/// idempotent.
class PreKeyUploadResult {
  const PreKeyUploadResult({required this.stored, required this.total});

  factory PreKeyUploadResult.fromJson(Map<String, dynamic> json) =>
      PreKeyUploadResult(
        stored: json['stored'] as int,
        total: json['total'] as int,
      );

  final int stored;
  final int total;
}

/// Push platforms accepted by `PUT/DELETE /devices/{id}/push-token` (N §4.2).
abstract final class PushPlatforms {
  static const fcm = 'fcm';
  static const apns = 'apns';

  /// iOS PushKit token — stored separately from the regular APNs token.
  static const apnsVoip = 'apns-voip';
}
