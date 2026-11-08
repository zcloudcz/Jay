# calltype_protocol

The Jay (CallType) end-to-end protocol as a small, pure Dart package:

- `lib/crypto/`: X3DH + Double Ratchet sessions (`SessionManager`), the
  primitives (`SignalProtocol`: X25519, Ed25519, HKDF-SHA256,
  AES-256-GCM, HMAC-SHA256), long-term keys (`KeyManager`), signed device
  lists, pairwise group fan-out (`GroupCipher`) and backup encryption.
- `lib/store/`: the only state the protocol keeps, as interfaces
  (`ProtocolStore` = sessions + identity pins + one-time pre-key markers,
  `SecretStore` for key material) plus `MemoryProtocolStore`.
- `lib/messaging/`: payload codecs carried inside encrypted messages
  (agent payload, reactions, pins, polls, contact sync, history transfer).
- `lib/testing/`: test support only (the deterministic vector scenario),
  so `calltype_core` can replay the same vectors over its drift store.

It has no network, no database and no Flutter. Dependencies are `crypto`
and `cryptography` only; `test/dependency_rule_test.dart` fails on any
`dio`, `drift`, `signalr`, `flutter`, `sqlite3` or `calltype_core`
dependency or import (and CI runs it).

The client (`calltype_core`: REST, SignalR, auth, devices, drift schema)
builds on this package and implements `ProtocolStore` over its existing
tables (`DriftProtocolStore`). For now `calltype_core` re-exports these
libraries under its old `crypto/` and `messaging/` paths, so bots and the
app did not have to change their imports.

## Test

```bash
dart pub get
dart analyze
dart test
```

`test/vectors/session_v2.json` holds deterministic test vectors (fixed
keys, recorded random draws, exact envelopes). Regenerate them only on
purpose with `dart run tool/generate_vectors.dart`; a test fails when the
code no longer reproduces the committed file byte for byte.
