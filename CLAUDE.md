# CallType

End-to-end encrypted multiplatform messenger. Anonymous-first with optional
registration for cloud backup. Voice/video calls via WebRTC.

## What this is

A WhatsApp-like messaging app with strong privacy:
- **Anonymous by default** — no phone number, no email required. Each device
  gets a random ID (`CT-XXXX-XXXX`) and identity key pair on first launch.
- **Optional registration** (email + passphrase) enables cloud backup and
  multi-device sync.
- **E2E encryption** via Signal Protocol (X3DH + Double Ratchet). Server
  never sees plaintext. Messages stored as opaque encrypted blobs.
- **Store-and-forward** — server holds encrypted messages until delivered,
  then deletes. 30-day TTL.
- **Contact discovery** via QR code or invite link. No address book sync.

## Stack

| Layer | Tech |
|-------|------|
| **Client** | Flutter/Dart — single codebase for iOS, Android, Web |
| **Backend API** | ASP.NET Core 10 minimal API (net10.0) |
| **Real-time** | SignalR (WebSocket) |
| **Database (server)** | PostgreSQL via EF Core (Npgsql) |
| **Database (client)** | SQLite via drift (plaintext under OS/browser protection — **not** SQLCipher yet; web uses sqlite3 WASM + drift worker) |
| **E2EE** | Signal Protocol in pure Dart (`cryptography` package): X3DH + full Double Ratchet, X25519 + HKDF + AES-256-GCM |
| **Voice/Video** | WebRTC (`flutter_webrtc`) |
| **STUN/TURN** | Pluggable via `Turn:Provider`: `cloudflare` (Cloudflare TURN, credentials minted by API — beta default) or `shared-secret` (self-hosted coturn / DeskShare.Turn from `C:\GIT\ZCLOUD\RemoteDesktopNet`) |
| **File storage** | Azure Blob Storage (encrypted attachments + backups) |
| **Hosting** | Azure App Service Linux B1, **exactly one instance** (API + SignalR) · Static Web Apps Free (Flutter web, `https://calltype.zcloud.cz`) · PostgreSQL on an external server · private Blob Storage |
| **Push** | FCM HTTP v1 (Android/Web) + APNs (iOS — not implemented yet) |

## Project structure

```
CallType/
├── docs/superpowers/
│   ├── specs/2026-05-28-calltype-design.md   # Full design spec
│   └── plans/2026-05-28-calltype-implementation.md  # 26-task plan
├── src/
│   ├── server/
│   │   ├── CallType.Api/                       # ASP.NET Core backend
│   │   │   ├── Program.cs                      # Entry point, DI, middleware
│   │   │   ├── Data/AppDbContext.cs             # EF Core DbContext (8 entities)
│   │   │   ├── Models/                         # Entity models
│   │   │   ├── Endpoints/                      # Minimal API endpoint groups
│   │   │   ├── Hubs/                           # SignalR hubs
│   │   │   ├── Services/                       # Business logic services
│   │   │   └── Migrations/                     # EF Core migrations
│   │   └── CallType.Api.Tests/                 # Integration tests (Testcontainers)
│   └── client/calltype/                        # Flutter app
│       └── lib/
│           ├── core/crypto/                    # E2EE (pure Dart, `cryptography` pkg)
│           ├── core/network/                   # API client, SignalR, WebRTC
│           ├── core/storage/                   # drift SQLite DB, secure storage
│           ├── features/                       # Feature-first UI modules
│           └── shared/                         # Reusable widgets, models
└── CallType.sln
```

## Build & test

### Backend
```bash
dotnet build src/server/CallType.Api
dotnet test src/server/CallType.Api.Tests    # requires Docker (Testcontainers)
```

### Client
```bash
cd src/client/calltype
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter test
flutter run -d chrome
```

### Push notifications (FCM)

Server push uses the **FCM HTTP v1 API** (the legacy server-key API was shut
down by Google in June 2024). Configuration: put the *entire* Firebase service
account JSON (Firebase console → Project settings → Service accounts) into
`Push:FcmServiceAccountJson` (env: `Push__FcmServiceAccountJson`). Empty =
push disabled, messages still delivered via store-and-forward on next connect.
APNs (iOS) is a known gap — `PushNotificationService` logs and skips it.

### EF Core migrations
```bash
# Add migration
dotnet ef migrations add MigrationName --project src/server/CallType.Api
# Apply to DB
dotnet ef database update --project src/server/CallType.Api
```

## Database entities (server — PostgreSQL)

| Entity | Purpose | Key |
|--------|---------|-----|
| `Device` | Anonymous device identity + public keys | `DeviceId` (Guid) |
| `OneTimePreKey` | Single-use X3DH pre-keys | `Id` (auto), unique(DeviceId, KeyId) |
| `Account` | Optional registered account | `AccountId` (Guid), unique Email |
| `AccountDevice` | Links accounts to devices (multi-device) | Composite(AccountId, DeviceId) |
| `QueuedMessage` | Store-and-forward encrypted message blobs | `Id` (auto), index(RecipientId, CreatedAt) |
| `Group` | Group chat metadata | `GroupId` (Guid) |
| `GroupMember` | Group membership + roles | Composite(GroupId, DeviceId) |
| `Backup` | Backup metadata (blobs in Azure) | `Id` (auto) |

All timestamps are `DateTimeOffset` (UTC). Server never stores plaintext content.

## API endpoints

| Endpoint | Purpose | Status |
|----------|---------|--------|
| `GET /health` | Liveness (200 while the process is up) | ✅ Done |
| `GET /health/ready` | Readiness: PostgreSQL + Blob reachable, else 503 | ✅ Done |
| `POST /devices` | Register device + upload keys | ✅ Done |
| `GET /devices/{id}/key-bundle` | Fetch key bundle for X3DH | ✅ Done |
| `POST /accounts` | Register account (Argon2id) | ✅ Done |
| `POST /accounts/login` | Authenticate | ✅ Done |
| `POST /accounts/{id}/devices/{id}` | Link device to account | ✅ Done |
| `GET /accounts/{id}/devices` | List linked devices | ✅ Done |
| `POST /groups` | Create group | ✅ Done |
| `GET /groups/{id}/members` | List members | ✅ Done |
| `PUT /groups/{id}/members` | Add member | ✅ Done |
| `DELETE /groups/{id}/members/{id}` | Remove member | ✅ Done |
| `POST /backups` | Upload backup metadata | ✅ Done |
| `GET /backups/{accountId}` | List backups | ✅ Done |
| `DELETE /backups/{accountId}/{backupId}` | Free a backup slot (quota: 3 per account, 8 MiB each, 256 MiB total) | ✅ Done |
| `GET /turn/credentials` | Time-limited TURN credentials | ✅ Done |
| `SignalR /hub` | Message relay, typing, call signaling | ✅ Done |

## Conventions

- **Backend:** C# minimal API, one file per endpoint group. No controllers.
- **Client:** Feature-first folders. Provider for state management.
- **E2EE:** All messages encrypted client-side. Server = opaque relay.
- **Comments:** Write comments explaining WHY for non-obvious decisions.
  This is a firm project requirement — do not skip.
- **Tests:** Both unit and integration tests required. Integration tests use
  real PostgreSQL via Testcontainers (Docker required). No mocking the DB.
- **Timestamps:** Always `DateTimeOffset`, always UTC.

## Key design decisions

1. **Store-and-forward model** — server holds encrypted messages until
   delivered (max 30 days), then deletes. Not permanent storage.
2. **Signal Protocol for E2EE** — X3DH key agreement + full Double Ratchet
   in pure Dart (`cryptography` package). The initiator's first messages are
   pre-key messages carrying the X3DH prologue, so the responder establishes
   its session from the first incoming message (see `session_manager.dart`
   for the wire format). **Known limitations:** no header encryption, no
   signed pre-key signature verification (server doesn't store it), Sender
   Keys for groups pending. Document limits honestly anywhere user-facing.
3. **Anonymous identity** — device generates UUID + key pair. User Handle
   (`CT-XXXX-XXXX`) for human-readable discovery. QR code for contact exchange.
4. **Backup encryption** — independent passphrase-derived key (Argon2id).
   Server never sees backup content. Only for registered users.
5. **TURN provider is pluggable** — `ITurnCredentialProvider` with two
   implementations: `CloudflareTurnCredentialService` (Cloudflare TURN; no
   relay to operate, UDP/TCP/TLS included, config `Turn:Cloudflare:KeyId` +
   `Turn:Cloudflare:ApiToken`) and `TurnCredentialService` (HMAC shared-secret
   for self-hosted coturn / DeskShare.Turn from RemoteDesktopNet). The client
   response shape is identical; DTLS-SRTP keeps media end-to-end encrypted
   regardless of who relays it.
6. **Single App Service instance** (not Functions, not scaled out) — SignalR
   needs persistent WebSockets and call/message routing is in-process memory.
   Scaling beyond one instance needs a backplane and is a separate task. For
   the same reason EF migrations run at startup
   (`Database__ApplyMigrationsOnStartup=true`) — there is never a second migrator.
7. **Production config is validated at startup** —
   `ProductionConfigurationValidator` refuses to boot with dev secrets, a short
   JWT secret or missing CORS origins, naming the key but never the value.

## Related projects

- **RemoteDesktopNet** (`C:\GIT\ZCLOUD\RemoteDesktopNet`) — provides
  DeskShare.Stun and DeskShare.Turn servers. RFC 5389/5766 compliant .NET 8
  implementations with HMAC-SHA1 auth. CallType uses these for WebRTC
  NAT traversal.

## Spec & plan

- Full design spec: `docs/superpowers/specs/2026-05-28-calltype-design.md`
- Original implementation plan (26 tasks, 7 phases): `docs/superpowers/plans/2026-05-28-calltype-implementation.md`
- **Current work — beta completion:** `docs/superpowers/plans/2026-09-16-beta-zadani.md` (+ `-kontrakty`, `-vyvoj`, `-infrastruktura`); status and evidence in `docs/acceptance/` and `docs/ops/`.
- Next feature (not started): Channels — `docs/superpowers/plans/2026-09-16-channels.md`.

## Deploy

Manual, SHA-pinned GitHub Actions workflow `.github/workflows/deploy.yml`
(`gh workflow run deploy.yml -f commit_sha=<full sha> -f confirm_backup=true`):
tests → API + five client builds with manifests → OIDC deploy to the existing
App Service / Static Web App → smoke. It never provisions infrastructure; IaC
lives in `infra/beta-appservice.bicep`. `infra/main.bicep`, `infra/beta-vm.bicep`
and `infra/beta-compose.yml` are historical and must not be deployed.
