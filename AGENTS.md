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
| **Database (client)** | SQLite + SQLCipher via drift |
| **E2EE** | Signal Protocol in pure Dart (`cryptography` package): X3DH + full Double Ratchet, X25519 + HKDF + AES-256-GCM |
| **Voice/Video** | WebRTC (`flutter_webrtc`) |
| **STUN/TURN** | Pluggable via `Turn:Provider`: `cloudflare` (Cloudflare TURN, credentials minted by API — beta default) or `shared-secret` (self-hosted coturn / DeskShare.Turn from `C:\GIT\ZCLOUD\RemoteDesktopNet`) |
| **File storage** | Azure Blob Storage (encrypted attachments + backups) |
| **Hosting** | Azure Container Apps |
| **Push** | FCM HTTP v1 (Android) + APNs direct, HTTP/2 token auth (iOS) + Web Push with VAPID (browsers); generic localized texts only |

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
│   ├── client/calltype_protocol/               # Pure Dart protocol: crypto + wire format, no network/DB/Flutter (docs/protocol/)
│   ├── client/calltype_core/                   # Pure Dart client core: API client, SignalR, auth, devices, drift schema
│   └── client/calltype/                        # Flutter app
│       └── lib/
│           ├── core/network/                   # push, SignalR glue, WebRTC
│           ├── core/storage/                   # drift opener, secure storage
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

### Push notifications (FCM, APNs, Web Push)

Contract: `docs/superpowers/specs/2026-11-06-notifications.md`. Server pushes go
only to OFFLINE devices and are visible but generic and localized (`cs` locale
prefix -> Czech, else English): "New message", "New message in a group",
"Incoming call", "New post in a channel". No sender, group name or text ever
leaves the server (E2E; names would be metadata for Apple/Google). Data keys:
`type` (`message`|`group_message`|`incoming_call`|`channel_post`),
`conversationId` (group id, the sender's primary device id for 1:1, channel id),
`v=1`. Collapse per conversation: FCM `tag`/`collapse_key`, APNs
`apns-collapse-id`/`thread-id`, Web Push `Topic` (SHA-256 of the id, 32 chars).
A silent send (`SendReliable...Silent`, spec `2026-11-11-bot-ack-reactions` N1)
never pushes; bots use it for their reactions.
An `offer` call signal to an offline device sends `incoming_call` (muted only by
a 1:1 mute in mode `all`), unless the device can RING (iOS VoIP token, or
Android registered with `ringCalls`): then the hub keeps a pending call (offer +
ICE, 45 s, in memory, `PendingCallStore`), answers the caller `ringing` and
sends a VoIP push (`apns-push-type: voip`, topic `<BundleId>.voip`) or a
data-only FCM ring instead; hub `RequestPendingCalls` / `DeclinePendingCall`,
signals `ringing` / `cancelled`, Android `call_cancelled` push. Contract:
`docs/superpowers/specs/2026-11-06-call-ringing.md`. Dead tokens are cleared: FCM 404 `UNREGISTERED`,
APNs 410 or 400 `BadDeviceToken`/`Unregistered`, Web Push 404/410.

Code: `Services/Push/` (`IPushSender` per provider: `FcmSender`, `ApnsSender`,
`WebPushSender`; payload builders in `PushPayloads`), dispatch and token
clearing in `PushNotificationService`. Each provider uses its own named
HttpClient (`fcm`, `apns`, `webpush`) so tests swap in a fake handler.
Every provider is optional: empty settings = provider disabled (logged once at
startup), messages still arrive through store-and-forward.

| Setting (env: `__` for `:`) | Meaning |
|---|---|
| `Push:FcmServiceAccountJson` | The *entire* Firebase service account JSON (Firebase console -> Project settings -> Service accounts). FCM HTTP v1 only; the legacy server-key API was shut down in June 2024. |
| `Push:Apns:KeyId` | Key ID of the APNs auth key (.p8) |
| `Push:Apns:TeamId` | Apple team, default `DZR3FD9ZNT` |
| `Push:Apns:BundleId` | `apns-topic`, default `cz.zcloud.jay` |
| `Push:Apns:PrivateKeyP8` | PEM text of the .p8 file (with the BEGIN/END lines) |
| `Push:Apns:UseSandbox` | `true` only for builds run from Xcode; TestFlight and App Store use production (default `false`) |
| `Push:WebPush:PublicKey` | VAPID public key, base64url uncompressed P-256 point (87 chars); served by `GET /push/webpush-key` |
| `Push:WebPush:PrivateKey` | VAPID private key, base64url 32-byte scalar (43 chars) |
| `Push:WebPush:Subject` | VAPID contact, default `mailto:martin@zcloud.cz` |

APNs: HTTP/2 to `api.push.apple.com`, ES256 provider JWT signed with the .p8,
cached 50 min (Apple: refresh at most every 20 min, never older than 60).
Web Push: own RFC 8291 (aes128gcm) + RFC 8292 (VAPID) implementation on
`System.Security.Cryptography`, pinned to the RFC 8291 section 5 vector in
`WebPushTests`. A mismatched VAPID pair disables Web Push at startup.

Generate a VAPID key pair once per environment (keep the private key secret;
changing the pair invalidates every browser subscription):
```bash
openssl ecparam -name prime256v1 -genkey -noout -out vapid.pem
# Push:WebPush:PublicKey
openssl ec -in vapid.pem -pubout -outform DER | tail -c 65 | base64 -w0 | tr '/+' '_-' | tr -d '='
# Push:WebPush:PrivateKey
openssl ec -in vapid.pem -outform DER | tail -c +8 | head -c 32 | base64 -w0 | tr '/+' '_-' | tr -d '='
rm vapid.pem
```
(macOS: `base64` without `-w0`.)

### Channel moderation operator (`/admin/*`)

The operator web signs in with e-mail + authKey + TOTP (`POST /admin/session`).
An account is an operator when it matches EITHER list below; with both empty
every `/admin` route answers 404. The lists are re-checked on every operator
call, so removing an entry (or unlinking the listed device) cuts live sessions.
TOTP MFA must be enabled for the account first (app: Settings -> Account).

| Setting (env: `__` for `:`) | Meaning |
|---|---|
| `Moderation:OperatorAccountIds` | Array of account GUIDs (`Moderation__OperatorAccountIds__0=...`) |
| `Moderation:OperatorHandles` | Array of device handles, case-insensitive (`Moderation__OperatorHandles__0=CT-77NN-3FMS`); the account the device is linked to is the operator |
| `Moderation:SessionMinutes` | Operator token lifetime, default 30 (no refresh) |

### Encrypted media (`/media/*`)

Contract: `docs/superpowers/specs/2026-11-07-encrypted-media.md`. Large files,
voice, audio and video are encrypted on the client (AES-256-GCM per chunk,
key only inside the Signal message) and relayed through the API in chunks:
each chunk is staged as an Azure block of blob `media/{id}`, `complete`
commits the block list. The server never sees plaintext or keys. Completed
media lives `RetentionHours` after completion, an unfinished upload
`UploadWindowHours` after creation; `MediaCleanupService` deletes blob + row.
Device and account deletion (N09) delete the media of the device(s) at once.
All byte limits are encrypted bytes.

| Setting (env: `__` for `:`) | Default | Meaning |
|---|---|---|
| `Media:MaxFileBytes` | 5368709120 (5 GiB) | Max encrypted size of one file |
| `Media:RetentionHours` | 72 | Completed media lifetime from completion |
| `Media:UploadWindowHours` | 24 | Time to finish an upload |
| `Media:MaxActiveBytesPerDevice` | 10737418240 (10 GiB) | Uploading + completed, not expired, per uploader device |
| `Media:MaxDailyBytesPerDevice` | 21474836480 (20 GiB) | Declared bytes of uploads created in a rolling 24 h (deleted ones count) |
| `Media:MaxUploadsPerDay` | 500 | Uploads created per device in a rolling 24 h |
| `Media:MaxTotalBytes` | 536870912000 (500 GiB) | Whole installation, active bytes |
| `Media:CleanupIntervalMinutes` | 10 | Cleanup period |
| `Media:MaxConcurrentChunkUploadsPerDevice` | 8 | Chunk PUTs one device may have in flight (429 `media_rate_limited` above) |
| `RateLimiting:MediaPermitLimit` | 600 | Requests/min per device on chunk PUT + download GET (policy `media`) |

### EF Core migrations
```bash
# Add migration
dotnet ef migrations add MigrationName --project src/server/CallType.Api --context AppDbContext
# Apply to DB
dotnet ef database update --project src/server/CallType.Api
```

## Database entities (server — PostgreSQL)

| Entity | Purpose | Key |
|--------|---------|-----|
| `Device` | Anonymous device identity + public keys; push registration (`PushToken`, `PushPlatform`, `PushLocale`, `PushRingCalls`, iOS `VoipPushToken`); bots may publish a command menu (`BotCommandsJson`, public plaintext metadata like `DisplayName`) and an inbound policy (`BotInboundMode` `open`/`owners`, `BotInboundOwnerIds` uuid[] of owner identities; private, never returned to others) | `DeviceId` (Guid) |
| `OneTimePreKey` | Single-use X3DH pre-keys | `Id` (auto), unique(DeviceId, KeyId) |
| `Account` | Optional registered account | `AccountId` (Guid), unique Email |
| `AccountDevice` | Links accounts to devices (multi-device) | Composite(AccountId, DeviceId) |
| `QueuedMessage` | Store-and-forward encrypted message blobs | `Id` (auto), index(RecipientId, CreatedAt) |
| `Group` | Group chat metadata | `GroupId` (Guid) |
| `GroupMember` | Group membership + roles | Composite(GroupId, DeviceId) |
| `Backup` | Backup metadata (blobs in Azure) | `Id` (auto) |
| `MediaUpload` | Encrypted media metadata (blob `media/{Id}`): uploader device (no FK), encrypted `SizeBytes`, `ChunkSize`, `Status` `Uploading`/`Completed`/`Deleted` (text), `CreatedAt`, `CompletedAt`, `ExpiresAt` (upload deadline, then retention end) | `Id` (random Guid = download capability), index(UploaderDeviceId, CreatedAt), index(ExpiresAt) |
| `ConversationMute` | Per-device mute of a group or 1:1 (push skip) | `Id` (auto), unique(DeviceId, GroupId), unique(DeviceId, PeerPrimaryDeviceId) |
| `Channel` | Public one-way channel (plaintext), soft delete, operator suspension `SuspendedUntil` | `ChannelId` (Guid), unique Handle |
| `ChannelAdmin` | Delegated members, `Role` `admin` or `publisher` (publish + delete own posts only) | Composite(ChannelId, DeviceId) |
| `ChannelReport` | Abuse report (`Category`, optional `ContactEmail`, `GoodFaith`, `Status` open/dismissed/actioned, `DecisionId`); reporter never exposed | `Id` (auto), index(Status, CreatedAt) |
| `ModerationDecision` | Append-only operator decision = statement of reasons | `Id` (auto), index(ChannelId, CreatedAt) |

All timestamps are `DateTimeOffset` (UTC). Server never stores plaintext content.

## API endpoints

| Endpoint | Purpose | Status |
|----------|---------|--------|
| `GET /health` | Health check | ✅ Done |
| `POST /devices` | Register device + upload keys | ✅ Done |
| `GET /devices/{id}/key-bundle` | Fetch key bundle for X3DH; one caller DEVICE takes at most 5 one-time pre-keys per target per hour (in memory), further bundles come without `oneTimePreKey` (signed pre-key X3DH still works) | ✅ Done |
| `GET /devices/{id}/one-time-prekeys/count`, `POST /devices/{id}/one-time-prekeys` | Self only (else 403): count `{count}`; add `{"oneTimePreKeys":[{keyId,publicKey}]}` (1..100 per call, 32-byte keys, max 200 stored) -> `{count}`; 400 `invalid_prekeys`, 409 `duplicate_key_id`. Bots replenish below 20 (spec `2026-11-09-bot-access` A6) | ✅ Done |
| `PUT` / `GET /devices/{id}/bot-policy` | Bot inbound policy, self only and bot only (403, 403 `not_a_bot`): `{"mode":"open"\|"owners","owners":["CT-..."]}` (max 10 handles, resolved to identities; 400 `invalid_bot_policy`, 400 `unknown_owner`) -> 200 `{mode, owners}` (current handles). Default `open`. With `owners` the hub silently skips the bot's copy (same ack as success) of a 1:1 send from a non-owner identity and of a group send when no owner identity is a member; spec `2026-11-09-bot-access` A1/A2 | ✅ Done |
| `GET /devices/{id}/profile` | Public profile by device id, same fields as `GET /devices/by-handle/{handle}`: `{deviceId, userHandle, isBot, displayName}`; 404 unknown, 401 without auth; consumes no pre-key (used by the app to add a 1:1 peer as a contact) | ✅ Done |
| `POST /accounts` | Register account (Argon2id) | ✅ Done |
| `POST /accounts/login` | Authenticate | ✅ Done |
| `POST /accounts/{id}/devices/{id}` | Link device to account | ✅ Done |
| `GET /accounts/{id}/devices` | List linked devices | ✅ Done |
| `POST /groups` | Create group | ✅ Done |
| `GET /groups/{id}/members` | List members | ✅ Done |
| `PUT /groups/{id}/members` | Add member | ✅ Done |
| `DELETE /groups/{id}/members/{id}` | Remove member (admin), or leave: any device of the member's own identity may remove it, a companion by removing its primary; last admin gets 409 `code: last_admin`, auditor 409 `auditor_immutable` | ✅ Done |
| `PUT` / `GET /devices/{id}/bot-commands` | Bot command menu `{"commands":[{"command","description"}]}`: PUT only by the bot itself (403, 403 `not_a_bot`, 400 `invalid_bot_commands`; empty list clears), GET by any device (empty for a non-bot, 404 unknown) | ✅ Done |
| `PUT /devices/{id}/push-token` | Register push (self only, else 403): `{"platform":"fcm"\|"apns"\|"webpush","token","locale"?,"ringCalls"?}`; APNs = 64..200 hex, Web Push = `PushSubscription.toJSON()` as a JSON string (https endpoint, keys), max 2048; `ringCalls: true` (FCM only, else stored false) = the Android app rings on data-only call pushes; 400 `invalid_platform` / `invalid_token` / `invalid_locale`; 204 | ✅ Done |
| `DELETE /devices/{id}/push-token` | Clear token, platform, locale, `ringCalls` AND the VoIP token (self only, idempotent), 204 | ✅ Done |
| `PUT` / `DELETE /devices/{id}/voip-token` | iOS PushKit token for call ringing (self only, else 403): `{"token"}` 64..200 hex, stored lowercase; 400 `invalid_token`; 204. DELETE is idempotent | ✅ Done |
| `GET /push/webpush-key` | Anonymous, `{"publicKey"}` VAPID key (base64url) for `PushManager.subscribe`; 404 when Web Push is not configured | ✅ Done |
| `PUT /groups/{id}/bot-talk` | Bot conversation setting (admin) | ✅ Done |
| `PUT /groups/{id}/mute`, `PUT /mutes/direct/{id}`, `GET /mutes` | Per-device mute (push skip) | ✅ Done |
| `POST /backups` | Upload backup metadata | ✅ Done |
| `GET /backups/{accountId}` | List backups | ✅ Done |
| `GET /turn/credentials` | Time-limited TURN credentials | ✅ Done |
| `POST /media` | Create an encrypted media upload `{"size","chunkSize"}` (encrypted bytes, chunk 1 MiB+16..8 MiB+16) -> 201 `{id, chunkSize, chunkCount, uploadExpiresAt}`; 400 `invalid_media_size`, 413 `media_too_large`, 409 `media_quota_exceeded`, 429 `media_rate_limited`, 503 `media_storage_full` | ✅ Done |
| `PUT /media/{id}/chunks/{index}` | Stage one encrypted chunk (raw body, exact length), uploader only (else 404 `media_not_found`), rate policy `media`; 400 `invalid_chunk`, 409 `media_not_uploading`, 410 `media_expired`; 204 | ✅ Done |
| `GET /media/{id}/upload` | Resume state `{id, status, chunkCount, received, uploadExpiresAt, expiresAt?}`, uploader only | ✅ Done |
| `POST /media/{id}/complete` | Commit chunks -> 200 `{id, size, expiresAt}` (idempotent); 409 `media_incomplete` + `missing` | ✅ Done |
| `DELETE /media/{id}` | Cancel/delete (blob gone, row `Deleted` until createdAt + 24 h for the daily caps), uploader only, 204 idempotent | ✅ Done |
| `GET /media/{id}` | Download by ANY authenticated device (id = capability), 200 or 206 for `Range: bytes=a-`/`a-b`, `Cache-Control: no-store`, rate policy `media`; 404 `media_not_found`, 410 `media_expired` | ✅ Done |
| `POST /channels/{id}/report` | Abuse report with `category`/`contactEmail`/`goodFaith`, 200 receipt `{reportId, createdAt}` | ✅ Done |
| `GET /channels/reports/mine`, `GET /channels/{id}/moderation` | Reporter outcome / statements of reasons for owner, admin, publisher | ✅ Done |
| `PUT /channels/{id}/admins/{deviceId}` | Owner appoints `admin` or `publisher` (body `{"role"}` optional); bot posts labelled `byBot`, limited by `Channels:MaxBotPostsPerDay` (429 `bot_post_limit`); suspended channel -> 403 `channel_suspended` | ✅ Done |
| `POST /admin/session`, `/admin/*` | Operator moderation API (allowlist `Moderation:OperatorAccountIds` or `Moderation:OperatorHandles` + TOTP, token `scope=moderation` valid only on `/admin/*`): summary, report queue, case detail, decisions (+ CSV log), channel search, attachments | ✅ Done |
| `SignalR /hub` | Message relay, typing, call signaling; call ringing for offline callees (`RequestPendingCalls`, `DeclinePendingCall(callId)`, signals `ringing` / `cancelled`) | ✅ Done |
| `SignalR /hub` silent sends | `SendReliableMessageSilent`, `SendReliableGroupMessageSilent`, `SendReliableDirectFanoutSilent`, `SendReliableGroupFanoutSilent`: same arguments, validation, storage and delivery as the plain `SendReliable...` method, but never the "New message" push to an offline device. Separate names because SignalR binds arguments by count (an optional argument would break old clients); a new client on an old server gets `Failed to invoke '<name>'` and falls back to the plain method. Nothing stored, no migration. Bots send every reaction silently; the app does not use it. Spec `2026-11-11-bot-ack-reactions` N1 | ✅ Done |

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
6. **Azure Container Apps** (not Functions) — persistent WebSocket connections
   needed for SignalR. Functions have cold start + execution time limits.

## Related projects

- **RemoteDesktopNet** (`C:\GIT\ZCLOUD\RemoteDesktopNet`) — provides
  DeskShare.Stun and DeskShare.Turn servers. RFC 5389/5766 compliant .NET 8
  implementations with HMAC-SHA1 auth. CallType uses these for WebRTC
  NAT traversal.

## Spec & plan

- Full design spec: `docs/superpowers/specs/2026-05-28-calltype-design.md`
- Implementation plan (26 tasks, 7 phases): `docs/superpowers/plans/2026-05-28-calltype-implementation.md`
