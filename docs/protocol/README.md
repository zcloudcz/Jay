# Jay (CallType) protocol specification

Language-independent description of what travels between Jay devices, so a
bot or client can be written in another language (Python, C#, ...) and
interoperate with the Dart implementation.

Status: describes the code at the time of writing, byte for byte. The
reference implementation is `src/client/calltype_protocol` (pure Dart, no
network, no database). It has NOT been independently audited; see
`docs/security/crypto-baseline.md` for the honest status line, the
primitive inventory and the known limits.

| File | Content |
|---|---|
| [envelope.md](envelope.md) | Pairwise envelope v2 (JSON fields, session id, AAD, transport encoding) |
| [crypto.md](crypto.md) | X3DH and Double Ratchet steps, KDF constants, limits, identity bundle |
| [payloads.md](payloads.md) | The JSON payload inside an envelope: message types and their bodies |
| [devices.md](devices.md) | Signed device lists, fan-out to devices and to groups |
| [vectors.md](vectors.md) | Deterministic test vectors and how to replay them |
| `docs/superpowers/specs/2026-11-07-encrypted-media.md` | Encrypted media: the `media` object and the chunked AES-256-GCM file format (code: `calltype_protocol/lib/media/`) |

## Layers

```
transport   SignalR hub / REST (server routes opaque blobs per device)
              encryptedBody = base64( UTF-8( envelope JSON ) )
envelope    pairwise X3DH + Double Ratchet, one per recipient DEVICE   (envelope.md, crypto.md)
payload     UTF-8 JSON { "v": 1, "id", "type", "body", ... }           (payloads.md)
```

The server sees the outer routing data (sender, recipient device, message
id, group id) but never the payload. Everything that matters for trust is
inside the authenticated payload and is re-checked against the outer data
by the receiver (message id, group id).

## Conventions used in all files

- base64 = standard alphabet with padding (RFC 4648 section 4), unless a
  field says base64url.
- Keys: X25519 public and private keys and Ed25519 public keys and seeds are
  32 raw bytes, Ed25519 signatures 64 bytes; on the wire always base64.
- JSON produced for signing or as AAD is compact (no whitespace, `,` and
  `:` separators), keys in the order given, strings escaped like Dart's
  `jsonEncode` (only `"`, `\` and control characters; `/` and non-ASCII
  are NOT escaped). Python: `json.dumps(x, separators=(',', ':'),
  ensure_ascii=False)`.
- Domain-separation strings (`CallType-...`) are part of the protocol and
  never change; a new version gets a new string.
- Device and identity ids are UUID strings, compared lower case.

## For a second implementation

Start with `vectors.md`: implement X3DH and the ratchet from `crypto.md`,
feed the recorded random draws, and compare every envelope byte for byte.
Then payloads, then devices. Compatibility with the Dart code has only been
shown by the Dart code itself so far; a second, independent implementation
built from these files is the actual test of the specification (see the
self-audit plan).
