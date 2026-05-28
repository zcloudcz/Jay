# ZMessanger

End-to-end encrypted multiplatform messenger. Anonymous-first with optional
registration for cloud backup. Voice/video calls via WebRTC.

## What this is

A WhatsApp-like messaging app with strong privacy:
- **Anonymous by default** — no phone number, no email required. Each device
  gets a random ID (`ZM-XXXX-XXXX`) and identity key pair on first launch.
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
| **Database (client)** | SQLite + SQLCipher via drift |
| **E2EE** | Signal Protocol — libsignal (Rust) via FFI (mobile) / WASM (web) |
| **Voice/Video** | WebRTC (`flutter_webrtc`) |
| **STUN/TURN** | DeskShare.Stun + DeskShare.Turn from `C:\GIT\ZCLOUD\RemoteDesktopNet` |
| **File storage** | Azure Blob Storage (encrypted attachments + backups) |
| **Hosting** | Azure Container Apps |
| **Push** | FCM (Android) + APNs (iOS) |

## Project structure

```
ZMessanger/
├── docs/superpowers/
│   ├── specs/2026-05-28-zmessanger-design.md   # Full design spec
│   └── plans/2026-05-28-zmessanger-implementation.md  # 26-task plan
├── src/
│   ├── server/
│   │   ├── ZMessanger.Api/                     # ASP.NET Core backend
│   │   │   ├── Program.cs                      # Entry point, DI, middleware
│   │   │   ├── Data/AppDbContext.cs             # EF Core DbContext (8 entities)
│   │   │   ├── Models/                         # Entity models
│   │   │   ├── Endpoints/                      # Minimal API endpoint groups
│   │   │   ├── Hubs/                           # SignalR hubs
│   │   │   ├── Services/                       # Business logic services
│   │   │   └── Migrations/                     # EF Core migrations
│   │   └── ZMessanger.Api.Tests/               # Integration tests (Testcontainers)
│   └── client/zmessanger/                      # Flutter app (not yet created)
│       ├── lib/
│       │   ├── core/crypto/                    # E2EE (libsignal wrapper)
│       │   ├── core/network/                   # API client, SignalR, WebRTC
│       │   ├── core/storage/                   # SQLCipher DB, secure storage
│       │   ├── features/                       # Feature-first UI modules
│       │   └── shared/                         # Reusable widgets, models
│       └── native/libsignal/                   # Rust FFI bridge
└── ZMessanger.sln
```

## Build & test

### Backend
```bash
dotnet build src/server/ZMessanger.Api
dotnet test src/server/ZMessanger.Api.Tests    # requires Docker (Testcontainers)
```

### Client (once created)
```bash
cd src/client/zmessanger
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter test
flutter run -d chrome
```

### EF Core migrations
```bash
# Add migration
dotnet ef migrations add MigrationName --project src/server/ZMessanger.Api
# Apply to DB
dotnet ef database update --project src/server/ZMessanger.Api
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

## API endpoints (planned/implemented)

| Endpoint | Purpose | Status |
|----------|---------|--------|
| `GET /health` | Health check | ✅ Done |
| `POST /devices` | Register device + upload keys | Planned (Task 3) |
| `GET /devices/{id}/key-bundle` | Fetch key bundle for X3DH | Planned (Task 3) |
| `POST /accounts` | Register account | Planned (Task 5) |
| `POST /accounts/login` | Authenticate | Planned (Task 5) |
| `POST /groups` | Create group | Planned (Task 5) |
| `PUT /groups/{id}/members` | Manage membership | Planned (Task 5) |
| `POST /backups` | Upload encrypted backup | Planned (Task 5) |
| `GET /turn/credentials` | Time-limited TURN credentials | Planned (Task 5) |
| `SignalR /hub` | Message relay, typing, call signaling | Planned (Task 4) |

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
2. **Signal Protocol for E2EE** — X3DH key agreement + Double Ratchet for
   forward secrecy. Sender Keys for group chat.
3. **Anonymous identity** — device generates UUID + key pair. User Handle
   (`ZM-XXXX-XXXX`) for human-readable discovery. QR code for contact exchange.
4. **Backup encryption** — independent passphrase-derived key (Argon2id).
   Server never sees backup content. Only for registered users.
5. **STUN/TURN shared with RemoteDesktopNet** — custom .NET STUN (RFC 5389)
   and TURN (RFC 5766) servers from DeskShare project. No third-party dependency.
6. **Azure Container Apps** (not Functions) — persistent WebSocket connections
   needed for SignalR. Functions have cold start + execution time limits.

## Related projects

- **RemoteDesktopNet** (`C:\GIT\ZCLOUD\RemoteDesktopNet`) — provides
  DeskShare.Stun and DeskShare.Turn servers. RFC 5389/5766 compliant .NET 8
  implementations with HMAC-SHA1 auth. ZMessanger will use these for WebRTC
  NAT traversal.

## Spec & plan

- Full design spec: `docs/superpowers/specs/2026-05-28-zmessanger-design.md`
- Implementation plan (26 tasks, 7 phases): `docs/superpowers/plans/2026-05-28-zmessanger-implementation.md`
