/// Types of a controlled identity change (S6, contracts K9).
///
/// X0 delivers these types complete (they are plain data) and
/// `SessionManager` already THROWS [IdentityChangedException] where it used
/// to throw a bare `StateError`; persisting the pending change, the stream
/// and the accept/dismiss actions are implemented by stream S (S6).
library;

enum IdentityChangeDirection { incoming, outgoing }

/// The peer's identity keys differ from the pinned ones.
///
/// Extends [StateError] on purpose: existing callers and tests match on
/// StateError (identity_authentication_test.dart) and must keep working.
class IdentityChangedException extends StateError {
  IdentityChangedException(this.change)
    : super(
        'Contact identity changed. Verify the contact before starting a new '
        'session.',
      );

  final PendingIdentityChange change;
}

/// Invite-QR fingerprint did not match the server's key bundle: likely MITM.
class IdentityMismatchException extends StateError {
  IdentityMismatchException(this.peerDeviceId)
    : super('Contact key does not match the scanned code.');

  final String peerDeviceId;
}

/// A detected, not yet accepted identity change of a peer.
class PendingIdentityChange {
  const PendingIdentityChange({
    required this.peerDeviceId,
    required this.previousIdentityKey,
    required this.previousSigningKey,
    required this.newIdentityKey,
    required this.newSigningKey,
    required this.detectedAt,
    required this.direction,
  });

  final String peerDeviceId;

  /// base64
  final String previousIdentityKey;
  final String previousSigningKey;
  final String newIdentityKey;
  final String newSigningKey;

  /// UTC
  final DateTime detectedAt;
  final IdentityChangeDirection direction;

  Map<String, dynamic> toJson() => {
    'peerDeviceId': peerDeviceId,
    'previousIdentityKey': previousIdentityKey,
    'previousSigningKey': previousSigningKey,
    'newIdentityKey': newIdentityKey,
    'newSigningKey': newSigningKey,
    'detectedAt': detectedAt.toUtc().toIso8601String(),
    'direction': direction.name,
  };

  factory PendingIdentityChange.fromJson(Map<String, dynamic> j) =>
      PendingIdentityChange(
        peerDeviceId: j['peerDeviceId'] as String,
        previousIdentityKey: j['previousIdentityKey'] as String,
        previousSigningKey: j['previousSigningKey'] as String,
        newIdentityKey: j['newIdentityKey'] as String,
        newSigningKey: j['newSigningKey'] as String,
        detectedAt: DateTime.parse(j['detectedAt'] as String).toUtc(),
        direction: IdentityChangeDirection.values.byName(
          j['direction'] as String,
        ),
      );
}
