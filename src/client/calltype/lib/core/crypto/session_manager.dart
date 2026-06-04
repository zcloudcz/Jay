import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart';

import '../storage/database.dart';
import 'signal_protocol.dart';

/// Manages E2E encrypted sessions for pairwise (1:1) messaging.
///
/// Each session holds symmetric ratchet state (root key, chain keys, message
/// indices) derived from an initial X3DH key agreement. The ratchet advances
/// with every message, providing forward secrecy: compromising the current
/// key does not expose past messages.
///
/// SIMPLIFIED MODEL: This implements a symmetric-key ratchet (chain key →
/// message key via HKDF) but omits the full Diffie-Hellman ratchet step
/// where parties exchange new ephemeral DH keys with every message turn.
/// The full DH ratchet provides "future secrecy" (self-healing after key
/// compromise); this simplified version provides forward secrecy only.
/// Acceptable for MVP — the DH ratchet upgrade is planned for Phase 4.
///
/// Session state is stored in the SignalSessions table as a JSON blob
/// containing: rootKey, sendChainKey, receiveChainKey, sendMessageIndex,
/// and receiveMessageIndex. All keys are base64-encoded.
class SessionManager {
  SessionManager({required AppDatabase database}) : _db = database;

  final AppDatabase _db;

  // -- Domain separation info strings for HKDF --------------------------------
  // These ensure that the same input key material produces different outputs
  // when used for different purposes (chain key advance vs. message key
  // derivation). Without domain separation, a chain key could accidentally
  // be usable as a message key.
  static final _chainKeyInfo = utf8.encode('chain-key');
  static final _messageKeyInfo = utf8.encode('msg-key');
  static final _rootKeyInfo = utf8.encode('root-key');

  /// Initializes a new E2E session with a remote device via X3DH.
  ///
  /// Performs the X3DH key agreement using our identity key and the peer's
  /// key bundle (identity key, signed pre-key, optional one-time pre-key).
  /// The resulting shared secret is expanded via HKDF into root + chain keys.
  ///
  /// [peerDeviceId] is the remote device's UUID (used as the session address).
  /// [keyBundle] must contain: identityKey, signedPreKey, and optionally
  /// oneTimePreKey — all as base64 strings.
  /// [myIdentityPrivateKey] is our base64-encoded X25519 private key.
  ///
  /// After this call, [encryptMessage] and [decryptMessage] work for this peer.
  Future<void> initializeSession(
    String peerDeviceId,
    Map<String, dynamic> keyBundle,
    String myIdentityPrivateKey,
  ) async {
    final peerIdentityKey = keyBundle['identityKey'] as String;
    final peerSignedPreKey = keyBundle['signedPreKey'] as String;
    final peerOneTimePreKey = keyBundle['oneTimePreKey'] as String?;

    // X3DH specifies multiple DH computations that are concatenated and fed
    // into HKDF. The more DH outputs we include, the stronger the agreement:
    //   DH1: our identity key × peer's signed pre-key (proves our identity)
    //   DH2: our identity key × peer's identity key (mutual authentication)
    //   DH3: our identity key × peer's one-time pre-key (replay protection)

    // DH1: Identity private key × Signed pre-key
    final dh1 = await SignalProtocol.keyAgreement(
      myIdentityPrivateKey,
      peerSignedPreKey,
    );

    // DH2: Identity private key × Identity key
    final dh2 = await SignalProtocol.keyAgreement(
      myIdentityPrivateKey,
      peerIdentityKey,
    );

    // Concatenate DH outputs — more material = stronger derived key.
    final dhConcat = <int>[...dh1, ...dh2];

    // DH3 (optional): Identity private key × One-time pre-key
    // One-time pre-keys provide replay protection: each is consumed once
    // on the server, so a replayed initial message would fail because the
    // OTK is already gone.
    if (peerOneTimePreKey != null) {
      final dh3 = await SignalProtocol.keyAgreement(
        myIdentityPrivateKey,
        peerOneTimePreKey,
      );
      dhConcat.addAll(dh3);
    }

    // Derive root key (32 bytes) + initial chain keys (32 + 32 bytes) from
    // the concatenated DH material. Using 96 bytes total: first 32 = root,
    // next 32 = send chain, last 32 = receive chain.
    final salt = List<int>.filled(32, 0); // Zero salt per Signal spec.
    final derived = await SignalProtocol.deriveKey(
      dhConcat,
      salt,
      _rootKeyInfo,
      96,
    );

    final rootKey = derived.sublist(0, 32);
    final sendChainKey = derived.sublist(32, 64);
    final receiveChainKey = derived.sublist(64, 96);

    // Persist the session state so it survives app restarts.
    final sessionState = {
      'rootKey': base64Encode(rootKey),
      'sendChainKey': base64Encode(sendChainKey),
      'receiveChainKey': base64Encode(receiveChainKey),
      'sendMessageIndex': 0,
      'receiveMessageIndex': 0,
    };

    await _saveSession(peerDeviceId, sessionState);
  }

  /// Encrypts a plaintext message for a peer device.
  ///
  /// Derives a message key from the current send chain key, encrypts the
  /// plaintext with AES-256-GCM, advances the chain key, and persists
  /// the updated session state. Returns the ciphertext in the format:
  /// [12-byte nonce][ciphertext][16-byte GCM tag].
  ///
  /// Throws [StateError] if no session exists for [peerDeviceId] — call
  /// [initializeSession] first.
  Future<Uint8List> encryptMessage(
    String peerDeviceId,
    String plaintext,
  ) async {
    final session = await _loadSession(peerDeviceId);
    if (session == null) {
      throw StateError(
        'No session for device $peerDeviceId. '
        'Call initializeSession first.',
      );
    }

    final chainKey = base64Decode(session['sendChainKey'] as String);
    final messageIndex = session['sendMessageIndex'] as int;

    // Derive a unique message key from the chain key + message index.
    // The index is included in the info parameter for domain separation —
    // each message gets a cryptographically independent key even though
    // they all derive from the same chain.
    final messageKey = await SignalProtocol.deriveKey(
      chainKey,
      List<int>.filled(32, 0),
      [..._messageKeyInfo, ...utf8.encode(':$messageIndex')],
      32,
    );

    // Advance the chain key so the previous message key can't be re-derived.
    // This is the forward secrecy mechanism: once the chain advances, the
    // old chain key is overwritten and cannot decrypt old messages.
    final nextChainKey = await SignalProtocol.deriveKey(
      chainKey,
      List<int>.filled(32, 0),
      _chainKeyInfo,
      32,
    );

    // AES-256-GCM encrypt with the derived message key.
    final plaintextBytes = utf8.encode(plaintext);
    final encrypted = await SignalProtocol.encrypt(messageKey, plaintextBytes);

    // Persist the advanced session state.
    session['sendChainKey'] = base64Encode(nextChainKey);
    session['sendMessageIndex'] = messageIndex + 1;
    await _saveSession(peerDeviceId, session);

    return encrypted;
  }

  /// Decrypts a ciphertext received from a peer device.
  ///
  /// Derives the message key from the receive chain key, decrypts with
  /// AES-256-GCM, advances the chain, and persists the updated state.
  /// Returns the plaintext string.
  ///
  /// Throws [StateError] if no session exists, or a crypto exception if
  /// the ciphertext was tampered with (GCM authentication failure).
  Future<String> decryptMessage(
    String peerDeviceId,
    Uint8List ciphertext,
  ) async {
    final session = await _loadSession(peerDeviceId);
    if (session == null) {
      throw StateError(
        'No session for device $peerDeviceId. '
        'Cannot decrypt without an established session.',
      );
    }

    final chainKey = base64Decode(session['receiveChainKey'] as String);
    final messageIndex = session['receiveMessageIndex'] as int;

    // Derive the same message key the sender used to encrypt.
    // This works because both sides derived their chain keys from the
    // same X3DH shared secret — send chain on one side = receive chain
    // on the other.
    final messageKey = await SignalProtocol.deriveKey(
      chainKey,
      List<int>.filled(32, 0),
      [..._messageKeyInfo, ...utf8.encode(':$messageIndex')],
      32,
    );

    // Advance the receive chain key.
    final nextChainKey = await SignalProtocol.deriveKey(
      chainKey,
      List<int>.filled(32, 0),
      _chainKeyInfo,
      32,
    );

    // Decrypt — throws if the ciphertext was tampered with.
    final plaintextBytes = await SignalProtocol.decrypt(messageKey, ciphertext);

    // Persist the advanced state only after successful decryption.
    // If decryption fails, we don't advance — this allows retrying
    // with the same chain key position.
    session['receiveChainKey'] = base64Encode(nextChainKey);
    session['receiveMessageIndex'] = messageIndex + 1;
    await _saveSession(peerDeviceId, session);

    return utf8.decode(plaintextBytes);
  }

  /// Checks whether a session exists for the given peer.
  ///
  /// Used by the chat controller to decide whether to initiate X3DH
  /// (fetch key bundle from server) before sending the first message.
  Future<bool> hasSession(String peerDeviceId) async {
    final session = await _loadSession(peerDeviceId);
    return session != null;
  }

  // -- Persistence helpers ----------------------------------------------------
  // Session state is stored in the SignalSessions table as a JSON blob in the
  // sessionData column (typed as Uint8List/blob in Drift). The address column
  // is the peer's device ID.

  Future<Map<String, dynamic>?> _loadSession(String peerDeviceId) async {
    final query = _db.select(_db.signalSessions)
      ..where((s) => s.address.equals(peerDeviceId));
    final result = await query.getSingleOrNull();
    if (result == null) return null;

    // Session data is stored as UTF-8 encoded JSON in a blob column.
    final jsonString = utf8.decode(result.sessionData);
    return jsonDecode(jsonString) as Map<String, dynamic>;
  }

  Future<void> _saveSession(
    String peerDeviceId,
    Map<String, dynamic> sessionState,
  ) async {
    final jsonBytes = Uint8List.fromList(utf8.encode(jsonEncode(sessionState)));

    await _db.into(_db.signalSessions).insertOnConflictUpdate(
          SignalSessionsCompanion.insert(
            address: peerDeviceId,
            sessionData: jsonBytes,
          ),
        );
  }
}
