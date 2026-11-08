import 'dart:typed_data';

/// Persistence seam of [SessionManager]: everything the pairwise protocol
/// must remember between messages, and nothing else.
///
/// WHY interfaces instead of a database: the ratchet must be runnable and
/// auditable without SQLite, and its test vectors must not depend on a
/// storage engine. The client implements this over its drift schema
/// (`DriftProtocolStore` in calltype_core, same tables, same keys, same
/// bytes as before the split); tests and tools use [MemoryProtocolStore].
///
/// The three groups are separate interfaces so a reader sees exactly which
/// state the protocol touches. [SessionManager] takes one [ProtocolStore]
/// that implements all three, because they must share ONE transaction.
abstract interface class SessionStore {
  /// Runs [action] atomically: either every write inside it is kept, or
  /// none is. Nested calls join the outer transaction.
  ///
  /// This is what makes "ratchet advanced" and "message stored" one step:
  /// the caller (app inbox, bot) opens the transaction around
  /// `decryptMessage` plus its own writes, and the SessionManager's own
  /// transaction calls join it. A crash in the middle therefore neither
  /// advances the ratchet nor records the message.
  Future<T> transaction<T>(Future<T> Function() action);

  /// The serialized session stored under [address], or null.
  ///
  /// Addresses: `<peerDeviceId>` is the active session used for sending,
  /// `<peerDeviceId>:<sid>` an archived session per session id.
  Future<Uint8List?> loadSession(String address);

  /// Inserts or replaces the session stored under [address].
  Future<void> saveSession(String address, Uint8List data);

  /// All sessions whose address starts with [prefix]. The drift store uses
  /// SQL `LIKE '<prefix>%'` (ASCII case-insensitive) as it always did.
  Future<List<({String address, Uint8List data})>> listSessions(String prefix);

  /// Deletes the sessions stored under [addresses]; unknown ones are ignored.
  Future<void> deleteSessions(List<String> addresses);
}

/// Pinning of peer identities (trust on first use).
abstract interface class IdentityStore {
  /// The pinned fingerprint `identityKey|signingKey` (both base64) of
  /// [peerDeviceId], or null when the peer was never pinned.
  Future<String?> pinnedIdentity(String peerDeviceId);

  /// Pins (or re-pins) [fingerprint] for [peerDeviceId].
  Future<void> pinIdentity(String peerDeviceId, String fingerprint);

  /// The identity key stored with the peer's contact entry, or null when
  /// there is no contact. An empty list means "contact without a key yet".
  Future<Uint8List?> contactIdentityKey(String peerDeviceId);

  /// Stores [identityKey] on the peer's contact entry. Does nothing when
  /// the peer is not a contact.
  Future<void> setContactIdentityKey(
    String peerDeviceId,
    Uint8List identityKey,
  );
}

/// Durable markers of consumed one-time pre-keys.
///
/// A responder writes the marker in the same transaction as the new
/// session; the private key is erased only afterwards
/// (`SessionManager.finalizePreKeyCleanup`), so a crash between the two
/// leaves a marker that a retry finishes. A marked id is refused forever,
/// which is the replay protection of one-time pre-keys.
abstract interface class PreKeyMarkerStore {
  /// Whether one-time pre-key [keyId] was consumed.
  Future<bool> isPreKeyConsumed(int keyId);

  /// Marks [keyId] consumed by a session with [peerDeviceId].
  Future<void> markPreKeyConsumed(int keyId, String peerDeviceId);

  /// Ids of every consumed one-time pre-key.
  Future<List<int>> consumedPreKeyIds();
}

/// The single store a [SessionManager] works on.
abstract interface class ProtocolStore
    implements SessionStore, IdentityStore, PreKeyMarkerStore {}
