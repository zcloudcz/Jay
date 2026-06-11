# CallType

End-to-end encrypted, anonymous-first multiplatform messenger (WhatsApp-like).
No phone number, no email — each device gets a random ID (`CT-XXXX-XXXX`) and
key pair on first launch. Optional registration (email + passphrase) enables
encrypted cloud backup. Voice/video calls via WebRTC.

> **Naming note:** the git repository is named `ZMessanger` for historical
> reasons; the product, solution (`CallType.sln`), and all namespaces are
> **CallType**.

## Architecture

| Layer | Tech |
|-------|------|
| Client | Flutter/Dart (iOS, Android, Web) — `src/client/calltype` |
| Backend | ASP.NET Core 10 minimal API + SignalR — `src/server/CallType.Api` |
| Database | PostgreSQL (server, EF Core/Npgsql) + SQLite/SQLCipher (client, drift) |
| E2EE | Signal Protocol in pure Dart — X3DH + Double Ratchet, X25519 + HKDF + AES-256-GCM |
| Calls | WebRTC (`flutter_webrtc`), custom .NET STUN/TURN (shared with RemoteDesktopNet) |
| Files | Azure Blob Storage (encrypted backups) |
| Hosting | Azure Container Apps (Bicep in `infra/`), CI/CD via GitHub Actions |
| Push | FCM HTTP v1 (Android/Web); APNs not implemented yet |

The server is an opaque relay: messages are encrypted client-side and stored
as encrypted blobs only until delivered (store-and-forward, 30-day TTL).

## Security status — read before trusting it

- Messages are E2E encrypted with the Signal Protocol: X3DH key agreement
  (identity + ephemeral + signed pre-key + one-time pre-key) and the full
  Double Ratchet — per-message keys with forward secrecy, DH ratchet steps
  on every direction change for self-healing after key compromise, and
  skipped-key handling for out-of-order delivery. Message headers are bound
  to ciphertexts as AES-GCM authenticated data.
- **Not yet implemented:** header encryption (ratchet public keys travel in
  plaintext — message *content* is unaffected), signed pre-key signature
  verification (the server does not store the signature yet; identity
  authenticity rests on out-of-band QR verification), and Sender Keys for
  groups (group messages will use per-recipient fan-out).
- Backups are encrypted client-side with a passphrase-derived key (Argon2id);
  the server never sees plaintext or the passphrase.

## Quick start (local)

Requires Docker.

```bash
docker compose up --build
# API on http://localhost:8080, PostgreSQL on localhost:5432
```

Flutter client:

```bash
cd src/client/calltype
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run -d chrome
```

## Tests

```bash
dotnet test src/server/CallType.Api.Tests   # integration tests, requires Docker (Testcontainers)
cd src/client/calltype && flutter test      # client unit tests
```

## Configuration

Key settings (env-var form, see `appsettings.json` for defaults):

| Setting | Purpose |
|---------|---------|
| `ConnectionStrings__DefaultConnection` | PostgreSQL |
| `ConnectionStrings__BlobStorage` | Azure Blob (backups) |
| `Jwt__Secret` | JWT signing key, ≥ 32 chars — **must be overridden in production** |
| `Turn__SharedSecret` | TURN credential HMAC secret |
| `Push__FcmServiceAccountJson` | Whole Firebase service account JSON; empty = push disabled |
| `Cors__AllowedOrigins` | Allowed browser origins (array) |

## More docs

- `CLAUDE.md` — developer/AI-agent guide (conventions, endpoints, entities)
- `docs/superpowers/specs/` — design specs
- `infra/` — Azure Bicep templates
