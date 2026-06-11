import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart';

import '../storage/database.dart';
import 'key_manager.dart';
import 'signal_protocol.dart';

/// Manages E2E encrypted sessions for pairwise (1:1) messaging using the
/// Signal Protocol: X3DH key agreement + the full Double Ratchet.
///
/// ## How a session starts
///
/// The INITIATOR (Alice) fetches the peer's key bundle from the server and
/// calls [initiateSession]. X3DH combines four DH computations into a shared
/// secret SK, and the peer's signed pre-key becomes the first remote ratchet
/// key. Alice's first messages are "pre-key messages" — they carry her
/// identity key, an ephemeral key, and the consumed one-time pre-key id, so
/// the RESPONDER (Bob) can run his side of X3DH when the first message
/// arrives (no [initiateSession] call on Bob's side; [decryptMessage]
/// establishes his session automatically).
///
/// ## The Double Ratchet
///
/// Every message carries a header: the sender's current ratchet public key,
/// the previous chain length (pn) and the message number (n). When a message
/// arrives with a NEW ratchet key, the receiver performs a DH ratchet step —
/// mixing fresh DH output into the root key — which gives the protocol its
/// self-healing property ("future secrecy"): compromise of current keys is
/// repaired as soon as one uncompromised round-trip completes. Within a
/// chain, keys advance with HMAC (forward secrecy), and out-of-order
/// messages are handled by storing skipped message keys.
///
/// The header travels in plaintext (the server must route the blob without
/// understanding it) but is bound to the ciphertext as AES-GCM additional
/// authenticated data — tampering with it breaks decryption.
///
/// KNOWN LIMITATION: the signed pre-key signature is not verified because
/// the server does not yet store/serve it. Identity authenticity therefore
/// rests on out-of-band verification (QR contact exchange). Header
/// encryption (a Signal extension) is also not implemented.
///
/// ## Wire format
///
/// Envelopes are JSON (the caller base64-encodes for transport):
/// ```json
/// { "v": 1, "t": "pk" | "m",
///   "ik": "...", "ek": "...", "pkid": 3,   // pre-key messages only
///   "rk": "...", "pn": 0, "n": 0,           // Double Ratchet header
///   "c": "..." }                             // base64 ciphertext
/// ```
class SessionManager {
  SessionManager({
    required AppDatabase database,
    required KeyManager keyManager,
  })  : _db = database,
        _keyManager = keyManager;

  final AppDatabase _db;
  final KeyManager _keyManager;

  /// Maximum number of message keys to skip within one chain. Bounds the
  /// work an attacker can force by sending a huge message number, and the
  /// number of keys we must derive for genuinely out-of-order delivery.
  static const _maxSkip = 256;

  /// Cap on stored skipped message keys per session. Oldest entries are
  /// evicted first — a very old out-of-order message then becomes
  /// undecryptable, which is the standard Signal trade-off.
  static const _maxStoredSkippedKeys = 512;

  // -- HKDF domain separation --------------------------------------------------
  static final _x3dhInfo = utf8.encode('CallType-X3DH-v1');
  static final _rootInfo = utf8.encode('CallType-DR-Root-v1');

  // KDF_CK constants per the Double Ratchet spec: message key = HMAC(ck, 0x01),
  // next chain key = HMAC(ck, 0x02).
  static const _mkSeed = [0x01];
  static const _ckSeed = [0x02];

  // ===========================================================================
  // Session initiation (Alice — the side that fetches the key bundle)
  // ===========================================================================

  /// Initializes a new E2E session with a remote device via X3DH, as the
  /// session INITIATOR.
  ///
  /// [keyBundle] is the server's key-bundle response: `identityKey` and
  /// `signedPreKey` as base64 strings, plus optionally `oneTimePreKey`
  /// as `{ keyId, publicKey }`.
  ///
  /// After this call, [encryptMessage] produces pre-key messages that let
  /// the peer establish their side without any prior contact.
  Future<void> initiateSession(
    String peerDeviceId,
    Map<String, dynamic> keyBundle,
  ) async {
    final identity = await _keyManager.getOrCreateIdentityKeyPair();
    final peerIdentityKey = keyBundle['identityKey'] as String;
    final peerSignedPreKey = keyBundle['signedPreKey'] as String;
    final peerOneTime = keyBundle['oneTimePreKey'] as Map<String, dynamic>?;

    // Fresh ephemeral key — used only for this handshake, then discarded.
    // It makes SK unique per session even when the same one-time pre-key
    // situation repeats, and contributes forward secrecy to the handshake.
    final ephemeral = await SignalProtocol.generateKeyPair();

    // X3DH (initiator side):
    //   DH1 = DH(IK_a,  SPK_b) — binds OUR identity to the session
    //   DH2 = DH(EK_a,  IK_b)  — binds THEIR identity to the session
    //   DH3 = DH(EK_a,  SPK_b) — fresh entropy from the ephemeral key
    //   DH4 = DH(EK_a,  OPK_b) — replay protection (if an OPK was available)
    final dh1 = await SignalProtocol.keyAgreement(
        identity['privateKey']!, peerSignedPreKey);
    final dh2 = await SignalProtocol.keyAgreement(
        ephemeral['privateKey']!, peerIdentityKey);
    final dh3 = await SignalProtocol.keyAgreement(
        ephemeral['privateKey']!, peerSignedPreKey);

    final dhConcat = <int>[
      // 32 bytes of 0xFF prefix per the X3DH spec ("F") — domain-separates
      // the KDF input from raw DH outputs in other protocol contexts.
      ...List<int>.filled(32, 0xFF),
      ...dh1, ...dh2, ...dh3,
    ];

    int? usedPreKeyId;
    if (peerOneTime != null) {
      usedPreKeyId = peerOneTime['keyId'] as int;
      final dh4 = await SignalProtocol.keyAgreement(
          ephemeral['privateKey']!, peerOneTime['publicKey'] as String);
      dhConcat.addAll(dh4);
    }

    final sk = await SignalProtocol.deriveKey(
        dhConcat, List<int>.filled(32, 0), _x3dhInfo, 32);

    // Double Ratchet init (initiator): the peer's signed pre-key acts as
    // their first ratchet key. We generate our first ratchet pair and
    // immediately perform the first half of a DH ratchet step so we can
    // send before the peer ever comes online.
    final ratchetPair = await SignalProtocol.generateKeyPair();
    final dhOut = await SignalProtocol.keyAgreement(
        ratchetPair['privateKey']!, peerSignedPreKey);
    final derived = await _kdfRoot(sk, dhOut);

    final state = <String, dynamic>{
      'rk': base64Encode(derived.rootKey),
      'dhsPub': ratchetPair['publicKey'],
      'dhsPriv': ratchetPair['privateKey'],
      'dhr': peerSignedPreKey,
      'cks': base64Encode(derived.chainKey),
      'ckr': null,
      'ns': 0,
      'nr': 0,
      'pn': 0,
      'skipped': <String, dynamic>{},
      // X3DH prologue replayed in every outgoing message until the peer's
      // first reply proves the session is established on both ends.
      'pending': {
        'ik': identity['publicKey'],
        'ek': ephemeral['publicKey'],
        'pkid': ?usedPreKeyId,
      },
    };

    await _saveSession(peerDeviceId, state);
  }

  // ===========================================================================
  // Encrypt
  // ===========================================================================

  /// Encrypts a plaintext message for a peer device. Returns the JSON
  /// envelope string (caller base64-encodes for transport).
  ///
  /// Throws [StateError] if no session exists for [peerDeviceId] — the
  /// sending side must call [initiateSession] first.
  Future<String> encryptMessage(String peerDeviceId, String plaintext) async {
    final state = await _loadSession(peerDeviceId);
    if (state == null) {
      throw StateError(
        'No session for device $peerDeviceId. Call initiateSession first.',
      );
    }

    // Derive the message key and advance the sending chain (KDF_CK).
    final cks = base64Decode(state['cks'] as String);
    final messageKey = await SignalProtocol.hmacSha256(cks, _mkSeed);
    state['cks'] = base64Encode(await SignalProtocol.hmacSha256(cks, _ckSeed));

    final n = state['ns'] as int;
    final pn = state['pn'] as int;
    final ratchetPub = state['dhsPub'] as String;
    state['ns'] = n + 1;

    // Bind the plaintext header to the ciphertext via AAD — see class docs.
    final aad = _headerAad(ratchetPub, pn, n);
    final ciphertext = await SignalProtocol.encrypt(
        messageKey, utf8.encode(plaintext), aad: aad);

    final pending = state['pending'] as Map<String, dynamic>?;
    final envelope = <String, dynamic>{
      'v': 1,
      't': pending != null ? 'pk' : 'm',
      if (pending != null) ...pending,
      'rk': ratchetPub,
      'pn': pn,
      'n': n,
      'c': base64Encode(ciphertext),
    };

    await _saveSession(peerDeviceId, state);
    return jsonEncode(envelope);
  }

  // ===========================================================================
  // Decrypt (including responder-side session establishment)
  // ===========================================================================

  /// Decrypts an incoming envelope (JSON string) from a peer device and
  /// returns the plaintext.
  ///
  /// If the envelope is a pre-key message and no session exists yet, the
  /// responder side of X3DH runs first, consuming the referenced one-time
  /// pre-key. Throws on unknown sessions for normal messages, on AEAD
  /// failures (tampering), and on malformed envelopes.
  Future<String> decryptMessage(String peerDeviceId, String envelopeJson) async {
    final envelope = jsonDecode(envelopeJson) as Map<String, dynamic>;

    var state = await _loadSession(peerDeviceId);
    if (state == null) {
      if (envelope['t'] != 'pk') {
        throw StateError(
          'No session for device $peerDeviceId and the message is not a '
          'pre-key message — cannot establish a session from it.',
        );
      }
      state = await _establishFromPreKeyMessage(envelope);
    }

    final ratchetPub = envelope['rk'] as String;
    final pn = envelope['pn'] as int;
    final n = envelope['n'] as int;
    final ciphertext = Uint8List.fromList(base64Decode(envelope['c'] as String));
    final aad = _headerAad(ratchetPub, pn, n);

    // 1. Out-of-order message from an older chain? Its key was stored when
    //    we skipped past it — decrypt with the stored key and we're done.
    final skipped = state['skipped'] as Map<String, dynamic>;
    final skippedKeyId = '$ratchetPub|$n';
    final storedKey = skipped.remove(skippedKeyId);
    if (storedKey != null) {
      final plaintext = await SignalProtocol.decrypt(
          base64Decode(storedKey as String), ciphertext, aad: aad);
      await _saveSession(peerDeviceId, state);
      return utf8.decode(plaintext);
    }

    // 2. New remote ratchet key? Skip remaining keys of the current receive
    //    chain (the sender's pn tells us its final length), then perform the
    //    DH ratchet step.
    if (state['dhr'] != ratchetPub) {
      await _skipMessageKeys(state, pn);
      await _dhRatchetStep(state, ratchetPub);
    }

    // 3. Skip ahead within the current chain if messages arrived out of
    //    order, storing their keys for later.
    await _skipMessageKeys(state, n);

    // 4. Derive this message's key and advance the receiving chain.
    final ckr = base64Decode(state['ckr'] as String);
    final messageKey = await SignalProtocol.hmacSha256(ckr, _mkSeed);
    state['ckr'] = base64Encode(await SignalProtocol.hmacSha256(ckr, _ckSeed));
    state['nr'] = (state['nr'] as int) + 1;

    // Decrypt BEFORE persisting — a failed (tampered/garbled) message must
    // not advance our state, or we would lose sync with the sender.
    final plaintext =
        await SignalProtocol.decrypt(messageKey, ciphertext, aad: aad);

    // Receiving any message proves the peer has our session — stop sending
    // the X3DH prologue (relevant when BOTH sides initiated simultaneously;
    // the regular case clears it on the initiator side).
    state['pending'] = null;

    await _saveSession(peerDeviceId, state);
    return utf8.decode(plaintext);
  }

  /// Responder side of X3DH — builds session state from the prologue of an
  /// incoming pre-key message (sender's identity key, ephemeral key, and
  /// the id of the one-time pre-key they consumed).
  Future<Map<String, dynamic>> _establishFromPreKeyMessage(
    Map<String, dynamic> envelope,
  ) async {
    final senderIdentityKey = envelope['ik'] as String?;
    final senderEphemeralKey = envelope['ek'] as String?;
    if (senderIdentityKey == null || senderEphemeralKey == null) {
      throw const FormatException(
          'Pre-key message is missing the X3DH prologue (ik/ek).');
    }

    final identity = await _keyManager.getOrCreateIdentityKeyPair();
    final signedPreKey = await _keyManager.getOrCreateSignedPreKey();
    final spkPriv = signedPreKey['privateKey'] as String;

    // Mirror of the initiator's four DH computations — same shared secrets,
    // computed from the opposite private keys. Order must match exactly.
    final dh1 = await SignalProtocol.keyAgreement(spkPriv, senderIdentityKey);
    final dh2 = await SignalProtocol.keyAgreement(
        identity['privateKey']!, senderEphemeralKey);
    final dh3 = await SignalProtocol.keyAgreement(spkPriv, senderEphemeralKey);

    final dhConcat = <int>[
      ...List<int>.filled(32, 0xFF),
      ...dh1, ...dh2, ...dh3,
    ];

    final preKeyId = envelope['pkid'] as int?;
    if (preKeyId != null) {
      final otkPriv = await _keyManager.consumeOneTimePreKey(preKeyId);
      if (otkPriv == null) {
        // Already consumed (or never existed) — likely a replayed initial
        // message. Refusing to proceed is exactly the protection one-time
        // pre-keys exist to provide.
        throw StateError(
            'One-time pre-key $preKeyId is unknown or already consumed.');
      }
      final dh4 =
          await SignalProtocol.keyAgreement(otkPriv, senderEphemeralKey);
      dhConcat.addAll(dh4);
    }

    final sk = await SignalProtocol.deriveKey(
        dhConcat, List<int>.filled(32, 0), _x3dhInfo, 32);

    // Double Ratchet init (responder): our signed pre-key pair IS our first
    // ratchet pair — the initiator already used its public half for their
    // first DH ratchet step. No chains yet: the first incoming header
    // triggers the receive-side ratchet step, and our first send triggers
    // the send side.
    return <String, dynamic>{
      'rk': base64Encode(sk),
      'dhsPub': signedPreKey['publicKey'],
      'dhsPriv': spkPriv,
      'dhr': null,
      'cks': null,
      'ckr': null,
      'ns': 0,
      'nr': 0,
      'pn': 0,
      'skipped': <String, dynamic>{},
      'pending': null,
    };
  }

  // ===========================================================================
  // Ratchet internals
  // ===========================================================================

  /// Performs a full DH ratchet step on receiving a new remote ratchet key:
  /// derive the new receiving chain, rotate our own ratchet pair, and derive
  /// the new sending chain. Two KDF_RK invocations per the spec.
  Future<void> _dhRatchetStep(
    Map<String, dynamic> state,
    String newRemoteRatchetKey,
  ) async {
    state['pn'] = state['ns'] as int;
    state['ns'] = 0;
    state['nr'] = 0;
    state['dhr'] = newRemoteRatchetKey;

    // Receiving chain: root key absorbs DH(our current pair, their new key).
    var dhOut = await SignalProtocol.keyAgreement(
        state['dhsPriv'] as String, newRemoteRatchetKey);
    var derived = await _kdfRoot(base64Decode(state['rk'] as String), dhOut);
    state['rk'] = base64Encode(derived.rootKey);
    state['ckr'] = base64Encode(derived.chainKey);

    // Sending chain: rotate our ratchet pair and absorb the new DH output.
    // This rotation is what heals the session after a key compromise.
    final newPair = await SignalProtocol.generateKeyPair();
    state['dhsPub'] = newPair['publicKey'];
    state['dhsPriv'] = newPair['privateKey'];

    dhOut = await SignalProtocol.keyAgreement(
        newPair['privateKey']!, newRemoteRatchetKey);
    derived = await _kdfRoot(base64Decode(state['rk'] as String), dhOut);
    state['rk'] = base64Encode(derived.rootKey);
    state['cks'] = base64Encode(derived.chainKey);
  }

  /// Advances the receiving chain up to (not including) message [until],
  /// storing each skipped message key so out-of-order messages can still
  /// be decrypted when they eventually arrive.
  Future<void> _skipMessageKeys(Map<String, dynamic> state, int until) async {
    if (state['ckr'] == null) {
      // No receiving chain yet (fresh responder session) — nothing to skip.
      return;
    }

    final nr = state['nr'] as int;
    if (until - nr > _maxSkip) {
      throw StateError(
          'Message number jumps too far ahead ($nr -> $until) — refusing to '
          'derive more than $_maxSkip skipped keys.');
    }

    final skipped = state['skipped'] as Map<String, dynamic>;
    var ckr = base64Decode(state['ckr'] as String);
    var n = nr;
    while (n < until) {
      final messageKey = await SignalProtocol.hmacSha256(ckr, _mkSeed);
      skipped['${state['dhr']}|$n'] = base64Encode(messageKey);
      ckr = Uint8List.fromList(await SignalProtocol.hmacSha256(ckr, _ckSeed));
      n++;
    }
    state['ckr'] = base64Encode(ckr);
    state['nr'] = n;

    // Evict oldest skipped keys beyond the cap. Dart maps preserve insertion
    // order, so the first keys are the oldest.
    while (skipped.length > _maxStoredSkippedKeys) {
      skipped.remove(skipped.keys.first);
    }
  }

  /// KDF_RK: derives a new root key + chain key from the current root key
  /// and a DH ratchet output. Root key acts as the HKDF salt per the spec.
  Future<({List<int> rootKey, List<int> chainKey})> _kdfRoot(
    List<int> rootKey,
    List<int> dhOutput,
  ) async {
    final derived =
        await SignalProtocol.deriveKey(dhOutput, rootKey, _rootInfo, 64);
    return (rootKey: derived.sublist(0, 32), chainKey: derived.sublist(32, 64));
  }

  /// Canonical AAD encoding of the message header. Sender and receiver must
  /// produce identical bytes, so the format is a fixed-order pipe join —
  /// never reuse the (key-order-sensitive) envelope JSON for this.
  List<int> _headerAad(String ratchetPub, int pn, int n) =>
      utf8.encode('v1|$ratchetPub|$pn|$n');

  // ===========================================================================
  // Persistence
  // ===========================================================================

  /// Checks whether a session exists for the given peer.
  ///
  /// Used by the chat controller to decide whether to initiate X3DH
  /// (fetch key bundle from server) before sending the first message.
  Future<bool> hasSession(String peerDeviceId) async {
    final session = await _loadSession(peerDeviceId);
    return session != null;
  }

  // Session state is stored in the SignalSessions table as a JSON blob in the
  // sessionData column (typed as Uint8List/blob in Drift). The address column
  // is the peer's device ID.

  Future<Map<String, dynamic>?> _loadSession(String peerDeviceId) async {
    final query = _db.select(_db.signalSessions)
      ..where((s) => s.address.equals(peerDeviceId));
    final result = await query.getSingleOrNull();
    if (result == null) return null;

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
