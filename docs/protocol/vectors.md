# Test vectors

Deterministic vectors generated from the Dart implementation, committed in
`src/client/calltype_protocol/test/vectors/`:

| File | Covers |
|---|---|
| `session_v2.json` | X3DH with a one-time pre-key, two pre-key messages, replies, out-of-order delivery over skipped keys, two DH ratchet steps, two rejected header tamperings |
| `device_list_v1.json` | Device-link consents, the canonical list payload and the primary's signature |

Generator: `dart run tool/generate_vectors.dart [out dir]` in
`calltype_protocol`. Replays: `test/vectors/*_test.dart` (memory store) and
`calltype_core/test/vectors/session_vectors_test.dart` (drift store). The
tests also regenerate both files and require them byte for byte, so a change
of the wire format or the key schedule cannot slip in unnoticed.

All binary values are standard base64 with padding.

## session_v2.json

- `devices.alice`, `devices.bob`: fixed long-term keys. `identityKey` and
  `signedPreKey` are X25519 pairs (`privateKey` = 32-byte seed),
  `signingKey.seed` is the Ed25519 seed, `oneTimePreKeys` Bob's one-time
  pre-keys (`keyId` 1 and 2). Alice has none.
- `bobBundle`: the key bundle the server would serve for Bob (identity
  bundle + one-time pre-key 1). Its `signature` is deterministic (Ed25519).
- `x3dh`: values computed directly from the primitives, independently of the
  session code: `ephemeralPublicKey`, `dh1`..`dh4`, `sk`, `firstRatchetDh`,
  `rootKey` and `sendingChainKey` after the initiator's first KDF_RK, and
  `sid`. The generator fails if the session code disagrees with them.
- `steps`: the conversation, in order. Every step has `op`, `by` and
  `draws`.
  - `draws`: the random bytes the implementation consumed during the step,
    in consumption order. 32-byte draws are X25519 private keys (in `initiate`:
    first EK, then the first ratchet key; in a decrypt that performs a DH
    ratchet step: the new ratchet key), 12-byte draws are AES-GCM nonces (one
    per `encrypt`). An implementation under test must take exactly these
    values instead of its random source.
  - `initiate` (Alice): `stateAfter` summarises Alice's session.
  - `encrypt`: `label` (e.g. `A0`, `B2`), `plaintext`, `envelope` = the
    exact envelope JSON string (byte-for-byte target), `stateAfter`.
  - `decrypt`: decrypts the envelope of the encrypt step with the same
    `label`; `plaintext` is the expected result.
  - `decrypt-rejects`: `envelope` is the labelled envelope with `tamper`
    (`pn` or `n`) incremented by one; decryption must fail and must not
    change the stored state (the following genuine `decrypt` still works).
    These steps may still consume a draw: the receiver performs the DH
    ratchet step in memory before the AEAD check fails.
  - `stateAfter`: `sid`, `rk`, `dhsPub`, `dhr`, `cks`, `ckr`, `ns`, `nr`,
    `pn`, `skippedKeys` (count) and `pending` (prologue still sent) of the
    acting device's active session for the peer. The field names follow the
    Dart state; their meaning is in crypto.md ("State").

How to replay in another implementation:

1. Load both devices' fixed keys. For Bob, also the one-time pre-keys.
2. Walk `steps`. Before each step, queue its `draws` as the only random
   source.
3. `initiate`: run X3DH as Alice with `bobBundle`; compare with `x3dh` and
   `stateAfter`.
4. `encrypt`: encrypt `plaintext`; your envelope must equal `envelope` as a
   string (key order, compact JSON). If you cannot control key order,
   compare parsed JSON and the AAD bytes instead (envelope.md).
5. `decrypt` / `decrypt-rejects`: feed the recorded envelope; compare the
   plaintext or the rejection, then `stateAfter`.
6. Check that every step consumed exactly its draws.

## device_list_v1.json

- `primary`: device id, Ed25519 `signingSeed` and public `signingKey`.
- `companions[]`: device id, Ed25519 `signingSeed`, X25519
  `identityPrivateKey`, and `entry` = the list entry (`deviceId`,
  `identityKey`, `signingKey`, `consentSig`).
- `payloadText`: the canonical payload JSON as text; `signed.payload` is its
  base64, `signed.signature` the primary's signature (devices.md).

An implementation must reproduce `consentSig`, `payloadText` and
`signature` exactly (Ed25519 is deterministic), accept the list with
`expectedPrimaryDeviceId = primary.deviceId`, and reject it with
`minVersion` 4 or with any payload byte flipped.
