# Envelope v2 (pairwise)

Source of truth: `src/client/calltype_protocol/lib/crypto/session_manager.dart`
(`encryptMessage`, `decryptMessage`, `_headerAad`, `_sessionId`).

One envelope encrypts one payload for ONE recipient device. A message to a
person with three devices, or to a group, is several envelopes
(see devices.md).

## Transport encoding

The envelope is a UTF-8 JSON object. On the hub and in REST bodies it
travels as `encryptedBody = base64(UTF-8(envelope JSON))`. The receiver
base64-decodes, UTF-8-decodes and parses it; the server never looks inside.

## Fields

| Field | Type | In | Meaning |
|---|---|---|---|
| `v` | int | all | Always `2`. Anything else is rejected. |
| `sid` | string | all | Session id: 64 lowercase hex characters, see below. Must match `^[0-9a-f]{64}$`. |
| `t` | string | all | `"pk"` = pre-key message (carries the X3DH prologue), `"m"` = normal message. |
| `identityBundle` | object | `pk` | The sender's signed identity bundle (crypto.md, "Identity bundle"). |
| `ik` | string | `pk` | Sender's X25519 identity public key (base64). Must equal `identityBundle.identityKey`. |
| `ek` | string | `pk` | Sender's X3DH ephemeral X25519 public key (base64). |
| `pkid` | int | `pk`, optional | Id of the recipient's one-time pre-key used in X3DH. Absent when the bundle had none. |
| `rk` | string | all | Sender's current ratchet public key (base64). |
| `pn` | int | all | Number of messages in the sender's previous sending chain. |
| `n` | int | all | Message number in the current sending chain, from 0. |
| `c` | string | all | base64 of `nonce (12) || AES-256-GCM ciphertext || tag (16)`. |

The Dart code writes the keys in exactly this order (`v, sid, t,
identityBundle, ik, ek, pkid, rk, pn, n, c`); receivers must not depend on
key order. Unknown keys are ignored.

A sender keeps sending `pk` messages (same `identityBundle`, `ik`, `ek`,
`pkid`) until it has received ANY message on that session; then it sends
`m`. Both sides may initiate at the same time, which yields two sessions
with different `sid` (see "Session selection").

Example (`pk`, values shortened):

```json
{"v":2,"sid":"9b1c...e0","t":"pk",
 "identityBundle":{"identityKey":"S7KW...lQ=","signedPreKey":"p0z/...wE=","signingKey":"299o...w00=","signature":"q3B...Aw=="},
 "ik":"S7KW...lQ=","ek":"Hk2...Ew=","pkid":1,
 "rk":"Vb1...cA=","pn":0,"n":0,"c":"AAEC...=="}
```

Complete real envelopes are in
`src/client/calltype_protocol/test/vectors/session_v2.json`.

## Session id

```
sid = lowercase_hex( SHA-256( UTF-8( "CallType-session-v2|" + ik_b64 + "|" + ek_b64 ) ) )
```

`ik_b64` and `ek_b64` are the base64 strings exactly as sent. The
initiator computes it from its own identity key and its ephemeral key; the
responder recomputes it from `ik` and `ek` and rejects the message if it
differs from `sid`.

## Additional authenticated data (AAD)

The header travels in plaintext (the server routes the blob) but is bound to
the ciphertext as AES-GCM AAD:

```
AAD = UTF-8( compact JSON array [ "v2", sid, rk, pn, n, prologue ] )

prologue = null                                   for t = "m"
prologue = [ ik, ek, pkid, identityBundle.identityKey,
             identityBundle.signedPreKey, identityBundle.signingKey,
             identityBundle.signature ]           for t = "pk"
```

`pkid` is JSON `null` when absent. Numbers are JSON integers, strings are
the base64/hex strings as in the envelope. Example for a normal message:

```
["v2","9b1c...e0","Vb1...cA=",3,0,null]
```

Changing any header field (or swapping the prologue) makes decryption fail.

## Receiving: validation order

1. Parse; `t` must be `pk` or `m` (else `FormatException`).
2. `v == 2` and `sid` matches `^[0-9a-f]{64}$`.
3. Look up the session stored under `<senderDeviceId>:<sid>`.
4. No session: only a `pk` message can create one. Check
   `identityBundle.identityKey == ik`, `ek` is a string, `sid` equals the
   recomputed session id, the bundle signature verifies, and the sender's
   identity matches what is pinned for the sender device (crypto.md,
   "Identity pinning"). Then run the responder side of X3DH.
5. Ratchet decrypt (crypto.md). Nothing is persisted when decryption fails.
6. On success the session is saved, a new session pins the sender identity,
   and the one-time pre-key `pkid` is marked consumed.

## Session selection (sending)

Each device keeps every session per peer under `<peer>:<sid>` (at most 16;
the oldest by establishment time are dropped) and one ACTIVE session under
`<peer>` used for sending. When a session is saved it becomes the active
one if there is none or if its `sid` sorts lexicographically lower or equal
to the active one's. Two devices that initiated simultaneously therefore
converge on the same session (the lower `sid`) and can still read messages
of the other one.
