# Key agreement and ratchet

Source of truth: `src/client/calltype_protocol/lib/crypto/session_manager.dart`,
`signal_protocol.dart` (primitives) and `key_manager.dart` (long-term keys,
identity bundle). The primitive inventory with parameters and the known
limits are in `docs/security/crypto-baseline.md`; this file gives the exact
steps so they can be reimplemented, and does not repeat the inventory.

The design follows Signal's X3DH and Double Ratchet specifications with the
differences listed at the end. It is a custom implementation, not libsignal.

## Primitives

| Name here | Definition |
|---|---|
| `DH(priv, pub)` | X25519 (RFC 7748), 32-byte private key used as given (the scalar is clamped by X25519 itself), 32-byte output |
| `HKDF(ikm, salt, info, L)` | HKDF-SHA256 (RFC 5869), extract with `salt`, expand with `info` (UTF-8) to `L` bytes |
| `HMAC(key, data)` | HMAC-SHA256 |
| `AEAD(key, nonce, pt, aad)` | AES-256-GCM, 12-byte random nonce, 16-byte tag; wire form `nonce || ct || tag` |
| `Sign` / `Verify` | Ed25519 (RFC 8032), 32-byte seed as private key |

## Long-term keys of a device

- `IK`: X25519 identity key pair.
- `SPK`: X25519 signed pre-key pair, key id 1. Never rotated (known limit).
  It is also the responder's first ratchet key pair.
- `OPK_i`: one-time X25519 pre-keys, key ids 1..100. The server hands out
  one per key-bundle fetch.
- `SK_sig`: Ed25519 signing key. It signs the identity bundle, the device
  list and the device-link consent.

### Identity bundle

```
identityBundle = { "identityKey": b64(IK.pub), "signedPreKey": b64(SPK.pub),
                   "signingKey": b64(SK_sig.pub), "signature": b64(sig) }
sig = Sign(SK_sig, UTF-8("CallType-SignedIdentity-v1") || 0x00 || IK.pub || SPK.pub)
```

`verifyIdentityBundle` requires all four fields, lengths 32/32/32/64, and a
valid signature. An unsigned (legacy) bundle is rejected.

The server's key bundle for a device is the identity bundle plus an
optional `"oneTimePreKey": {"keyId": int, "publicKey": b64}`.

### Identity pinning

On first use the receiver pins `peer_identity:<deviceId> = identityKey|signingKey`
(both base64). Any later bundle or prologue for that device with a different
pair is rejected ("Contact identity changed"). If the local contact entry
already holds an identity key, it must equal `identityKey` too. There is no
safety-number check yet (trust on first use).

## X3DH

Constants: `F = 32 bytes of 0xFF`, `salt0 = 32 bytes of 0x00`,
`info = "CallType-X3DH-v1"`.

Initiator A, with B's verified key bundle:

```
EK  = fresh X25519 key pair
DH1 = DH(IK_A.priv, SPK_B.pub)
DH2 = DH(EK.priv,   IK_B.pub)
DH3 = DH(EK.priv,   SPK_B.pub)
DH4 = DH(EK.priv,   OPK_B.pub)          only if the bundle had a one-time pre-key
SK  = HKDF(F || DH1 || DH2 || DH3 [|| DH4], salt0, "CallType-X3DH-v1", 32)
```

Responder B, from a `pk` envelope (`ik` = IK_A.pub, `ek` = EK.pub, `pkid`):

```
DH1 = DH(SPK_B.priv, IK_A.pub)
DH2 = DH(IK_B.priv,  EK.pub)
DH3 = DH(SPK_B.priv, EK.pub)
DH4 = DH(OPK_B[pkid].priv, EK.pub)      only if pkid is present
SK  = same HKDF as above
```

If `pkid` is present but that pre-key is unknown or already marked consumed,
the message is refused (replay protection). The private one-time key is
erased only after the receiving transaction committed; until then a durable
marker `consumed_prekey:<id>` makes a retry refuse a second use while still
being able to finish the erase.

## Double Ratchet

```
KDF_RK(rk, dh) = HKDF(dh, rk, "CallType-DR-Root-v1", 64)  ->  (rk' = bytes 0..31, ck = bytes 32..63)
KDF_CK(ck)     = (mk = HMAC(ck, 0x01), ck' = HMAC(ck, 0x02))
```

### State

`rk` root key, `DHs` own ratchet key pair, `DHr` peer ratchet public key,
`CKs`/`CKr` sending/receiving chain keys, `Ns`/`Nr` message numbers, `PN`
length of the previous sending chain, `skipped` map
`"<ratchet pub b64>|<n>" -> message key`, `pending` X3DH prologue.

### Initialisation

Initiator, right after X3DH:

```
DHs        = fresh X25519 key pair
DHr        = SPK_B.pub
(rk, CKs)  = KDF_RK(SK, DH(DHs.priv, SPK_B.pub))
CKr = none, Ns = Nr = PN = 0
pending    = { identityBundle, ik: IK_A.pub, ek: EK.pub, pkid }
```

Responder, after X3DH: `rk = SK`, `DHs = SPK_B`, `DHr = none`, no chains,
`Ns = Nr = PN = 0`, `pending = none`.

### Encrypt

```
(mk, CKs) = KDF_CK(CKs)
header    = (rk: DHs.pub, pn: PN, n: Ns);  Ns += 1
c         = AEAD(mk, random nonce, UTF-8(payload), AAD(header, sid, pending))
t         = "pk" if pending else "m"
```

AAD is defined in envelope.md.

### Decrypt (header `rk`, `pn`, `n`)

1. If `skipped` holds `"<rk>|<n>"`: remove it, decrypt with that key, save
   the state (without the used key), done. This path does not clear
   `pending`.
2. If `rk != DHr`: skip message keys of the current receiving chain up to
   `pn` (step "Skip"), then do a DH ratchet step:
   ```
   PN = Ns; Ns = 0; Nr = 0; DHr = rk
   (rk, CKr) = KDF_RK(rk, DH(DHs.priv, DHr))
   DHs       = fresh X25519 key pair
   (rk, CKs) = KDF_RK(rk, DH(DHs.priv, DHr))
   ```
3. Skip message keys of the receiving chain up to `n`.
4. `(mk, CKr) = KDF_CK(CKr)`, `Nr += 1`, decrypt with `mk`.
5. Only if decryption succeeded: clear `pending`, persist the new state.

Skip(until): if there is no receiving chain yet, do nothing. If
`until - Nr > 256` (`MAX_SKIP`), refuse the message. Otherwise for each
`Nr < until` store `skipped["<DHr>|<Nr>"] = mk` and advance `CKr`. At most
512 skipped keys are kept per session; the oldest are evicted first, so a
very old out-of-order message can become unreadable.

A failed decryption (tampered header or ciphertext, wrong key) leaves the
stored state untouched, so a valid retry still works.

## Persistence and atomicity

The protocol keeps exactly three kinds of state (`lib/store/protocol_store.dart`):
sessions (active under `<peer>`, all under `<peer>:<sid>`), identity pins,
and consumed one-time pre-key markers. Long-term private keys live in a
separate secret store. A receiver must commit "ratchet advanced" and "message
recorded as seen" in ONE transaction, or a crash in between either loses
the message (key spent, nothing stored) or processes it twice.

## Differences from Signal

- Header encryption is not used: `rk`, `pn`, `n` are plaintext, protected
  as AAD only.
- The KDF info strings are CallType-specific (`CallType-X3DH-v1`,
  `CallType-DR-Root-v1`); KDF_CK uses the constants 0x01 and 0x02 as in the
  Signal spec.
- Envelope v2 adds the session id `sid` and puts the whole X3DH prologue,
  including the signed identity bundle, into the AAD.
- The signed pre-key is not rotated; there is no PQ (PQXDH) step.
- Groups have no Sender Keys: every group message is encrypted pairwise
  per member device (devices.md).
