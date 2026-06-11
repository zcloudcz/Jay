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
| E2EE | Simplified Signal Protocol in pure Dart — X25519 + HKDF + AES-256-GCM |
| Calls | WebRTC (`flutter_webrtc`), custom .NET STUN/TURN (shared with RemoteDesktopNet) |
| Files | Azure Blob Storage (encrypted backups) |
| Hosting | Azure Container Apps (Bicep in `infra/`), CI/CD via GitHub Actions |
| Push | FCM HTTP v1 (Android/Web); APNs not implemented yet |

The server is an opaque relay: messages are encrypted client-side and stored
as encrypted blobs only until delivered (store-and-forward, 30-day TTL).

## Security status — read before trusting it

- Messages are E2E encrypted with X25519 key agreement (X3DH-style pre-key
  exchange) and AES-256-GCM, with a symmetric chain-key ratchet.
- **Not yet implemented:** the full Signal Double Ratchet (DH ratchet with
  header encryption). Practical impact: if a device's chain key is
  compromised, forward secrecy for that conversation is limited until a new
  session is established. Planned as Phase 4.
- Group messages are encrypted per-recipient (fan-out); Sender Keys are
  planned together with the Double Ratchet.
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
