# CallType (product name: Jay)

> **Branding:** users see **Jay** (app name, icons, web title, theme petrol `#003840` + orange `#FF8545`, mark in `www/assets/jay-mark.svg`, icon masters in `src/client/calltype/assets/brand/`, regenerate with `dart run flutter_launcher_icons`). `CallType` stays as the internal code name everywhere in code and infrastructure. Never rename the `CallType-*` strings in `core/crypto/` — they are protocol domain separators; changing them breaks every existing session.

End-to-end encrypted multiplatform messenger. Anonymous-first with optional
registration for cloud backup. Voice/video calls via WebRTC.

## What this is

A WhatsApp-like messaging app with strong privacy:
- **Anonymous by default** — no phone number, no email required. Each device
  gets a random ID (`CT-XXXX-XXXX`) and identity key pair on first launch.
- **Optional registration** (email + passphrase) enables cloud backup.
- **Multi-device** without an account: a new device is linked by QR code from
  the primary, which signs the device list (spec
  `docs/superpowers/specs/2026-10-13-multi-device-sync-design.md`).
- **E2E encryption** via Signal Protocol (X3DH + Double Ratchet). Server
  never sees plaintext. Messages stored as opaque encrypted blobs.
- **Store-and-forward** — server holds encrypted messages until delivered,
  then deletes. 30-day TTL.
- **Contact discovery** via QR code or invite link. No address book sync.
- **Two modes, one product.** Anonymous E2E (above, unchanged) and **Business**:
  organization + roles, a VISIBLE silent auditor member in every business
  conversation, append-only metadata archive, emergency channel. Never a
  hidden audit. Business mode is optional on the server: ON only when
  `ConnectionStrings:Audit` is set, otherwise its endpoints answer 503
  `business_mode_disabled`. Status: `docs/acceptance/business-mode.md`.

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
| **Hosting** | Azure App Service Linux B1, **exactly one instance** (API + SignalR) · Static Web Apps Free (Flutter web, `https://jay.zcloud.cz`) · PostgreSQL on an external server · private Blob Storage |
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
│   │   ├── CallType.Audit/                     # Business mode: separate Audit DB (own DbContext + migrations), org/roles, hash-chained archive, emergency kits
│   │   └── CallType.Api.Tests/                 # Integration tests (Testcontainers)
│   ├── bots/                                   # Pure Dart, no Flutter SDK
│   │   ├── calltype_bot/                       # Headless E2E device runtime
│   │   ├── hermes_bridge/                      # First bot: bridge to Hermes Agent
│   │   └── jay_archiver/                       # The auditor device: archives business groups (+ live E2E tests in test/e2e)
│   ├── client/calltype_core/                   # Pure Dart protocol core shared by app and bots: crypto, API client, SignalR, drift schema
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
# The drift schema lives in calltype_core and its database.g.dart is
# git-ignored — generate it there FIRST or the app does not compile.
cd src/client/calltype_core
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter test

cd ../calltype
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter test
flutter run -d chrome
```

### Bots and live E2E
```bash
cd src/bots/jay_archiver && dart test          # same for calltype_bot, hermes_bridge

# Live end-to-end (real crypto, real hub, real archiver) against local compose:
docker compose up -d --build api
cd src/bots/jay_archiver && JAY_E2E_API=http://localhost:8080 dart test test/e2e
```
The E2E tests are skipped without `JAY_E2E_API`. **Never point them at beta or
production** — the Audit database is append-only, every run leaves an
undeletable organization. The API allows 10 "auth" calls per minute per IP and
the two E2E files use exactly 10, so a re-run within the same minute gets 429.
Mocks of the server's JSON must be copied from the contract
(`docs/superpowers/plans/2026-09-18-business-mode-contracts.md`), not assumed:
the first live run found a client that was green against mocks of its own
wrong assumptions.

### Localization (client)

Standard Flutter `gen_l10n`, 19 languages (en template + cs, sk, de, fr, es,
it, pt, pl, nl, uk, ro, hu, zh, hi, ar, ru, ja, tr).

- **Where:** ARB files in `src/client/calltype/lib/l10n/app_<lang>.arb`,
  config in `l10n.yaml`. The generated `app_localizations*.dart` are
  git-ignored; `flutter pub get` regenerates them (`generate: true`), or run
  `flutter gen-l10n`.
- **Language comes from the OS / browser.** `MaterialApp` sets no `locale:`,
  there is no in-app switcher and nothing is persisted; unsupported languages
  fall back to English (`preferred-supported-locales: [en]`). iOS needs the
  list in `ios/Runner/Info.plist` (`CFBundleLocalizations`), Android 13+ per-app
  language uses `android/.../res/xml/locales_config.xml`.
- **Add a string:** add the key (+ `@key` description / placeholders, ICU
  plural for counts — never concatenate) to `app_en.arb`, translate it in
  **all** other ARBs, use it as `context.l10n.myKey`
  (`lib/l10n/l10n.dart`). Code without a `BuildContext` returns an enum / code
  and a widget maps it to text (see `CallError`, `BackupError`,
  `channelErrorMessage`) — no global localization singleton. Not localized:
  logs, developer exception text, protocol strings, handles, "Jay", "BOT".
- **Add a language:** add `app_<lang>.arb` with every key, then add the code to
  `Info.plist`, `locales_config.xml` and the language list in
  `test/l10n/arb_consistency_test.dart`.
- **Guards:** `test/l10n/` checks key / placeholder / plural parity of every
  ARB, pumps screens in cs / de / ar (RTL) / unsupported locale, and fails on
  hard-coded `Text('…')` literals in `lib/features`, `lib/shared`, `lib/app`.
  `build/l10n_untranslated.json` must stay `{}`. Widget tests wrap screens
  with `test/helpers/localized_app.dart`.
- **Translations are machine-made and have not been reviewed by native
  speakers.** Treat wording fixes from native speakers as welcome, not as
  regressions. Security wording (channels are NOT end-to-end encrypted, bot
  notice, backup passphrase) must keep its meaning in every language.

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
An `offer` call signal to an offline device sends `incoming_call` (muted only by
a 1:1 mute in mode `all`). Dead tokens are cleared: FCM 404 `UNREGISTERED`,
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
| `Device` | Anonymous device identity + public keys; push registration (`PushToken`, `PushPlatform`, `PushLocale`); bots may publish a command menu (`BotCommandsJson`, public plaintext metadata like `DisplayName`) | `DeviceId` (Guid) |
| `OneTimePreKey` | Single-use X3DH pre-keys | `Id` (auto), unique(DeviceId, KeyId) |
| `Account` | Optional registered account | `AccountId` (Guid), unique Email |
| `AccountDevice` | Links accounts to devices (multi-device) | Composite(AccountId, DeviceId) |
| `QueuedMessage` | Store-and-forward encrypted message blobs | `Id` (auto), index(RecipientId, CreatedAt) |
| `Group` | Group chat metadata | `GroupId` (Guid) |
| `GroupMember` | Group membership + roles | Composite(GroupId, DeviceId) |
| `Backup` | Backup metadata (blobs in Azure) | `Id` (auto) |
| `ConversationMute` | Per-device mute of a group or 1:1 (push skip) | `Id` (auto), unique(DeviceId, GroupId), unique(DeviceId, PeerPrimaryDeviceId) |
| `Channel` | Public one-way channel; owned by an account (`OwnerAccountId`), soft delete (= operator termination too), denormalized `FollowerCount`, operator suspension `SuspendedUntil` (suspended while > now) | `ChannelId` (Guid), unique Handle (`CH-XXXX-XXXX`) |
| `ChannelAdmin` | Delegated members, `Role` `admin` or `publisher` (publish + delete own posts only); owner rights come from the account, not from a row here | Composite(ChannelId, DeviceId) |
| `ChannelPost` | **Plaintext** post (`Kind` text/image/poll), soft delete, 90-day retention | `PostId` (Guid, client-generated), index(ChannelId, CreatedAt DESC) |
| `ChannelFollower` | Follow link + `LastSeenPostAt`; never exposed by the API | Composite(ChannelId, DeviceId) |
| `ChannelReaction` | One whitelisted emoji per device per post; API returns totals only | Composite(PostId, DeviceId) |
| `ChannelPollVote` | One vote per device per poll; API returns totals only | Composite(PostId, DeviceId) |
| `ChannelReport` | Abuse report for the operator (`Category` illegal/terms/spam, optional `ContactEmail`, `GoodFaith`, `Status` open/dismissed/actioned, `ResolvedAt`, `DecisionId`); reporter never exposed, not even to the operator | `Id` (auto), index(Status, CreatedAt) |
| `ModerationDecision` | Append-only operator decision = statement of reasons (action, ground terms+rule K1..K10 or illegal+legal ground, explanation, `OperatorAccountId`, `ReportCount`) | `Id` (auto), index(ChannelId, CreatedAt) |
| `DeviceList` | Signed list of an identity's companion devices; opaque to the server (it never verifies the signature) | `PrimaryDeviceId` |
| `DeviceListMember` | Device to identity routing row, derived from the list on every PUT | `DeviceId` |

All timestamps are `DateTimeOffset` (UTC). Server never stores plaintext content
— with the single deliberate exception of channels, which are public and not E2E.

Business mode keeps its data in a **second, physically separate database**
(`calltype_audit`, `AuditDbContext` in `CallType.Audit`): organizations,
invites, enrollments, hash-chained `AuditRecord` (message METADATA only — never
content) and `AdminAuditEvent`, emergency kits/codes/drills. The running API
connects as a role that may only INSERT/SELECT (`infra/postgres/audit-roles.sql`);
schema changes are applied by a separate ops role. Treat it as append-only:
check every precondition BEFORE the first write, nothing can be cleaned up later.

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
| `POST /groups` | Create group (403 `companion_cannot_manage_groups` from a companion device) | ✅ Done |
| `GET /groups/{id}/members` | List members (+ public profile: handle, display name, isBot); a companion reads the groups of its identity | ✅ Done |
| `PUT /groups/{id}/members` | Add member | ✅ Done |
| `DELETE /groups/{id}/members/{id}` | Remove member | ✅ Done |
| `PUT` / `GET /devices/{id}/bot-commands` | Bot command menu `{"commands":[{"command","description"}]}`: PUT only by the bot itself (403, 403 `not_a_bot`, 400 `invalid_bot_commands`; empty list clears), GET by any device (empty for a non-bot, 404 unknown) | ✅ Done |
| `PUT /devices/{id}/push-token` | Register push (self only, else 403): `{"platform":"fcm"\|"apns"\|"webpush","token","locale"?}`; APNs = 64..200 hex, Web Push = `PushSubscription.toJSON()` as a JSON string (https endpoint, keys), max 2048; 400 `invalid_platform` / `invalid_token` / `invalid_locale`; 204 | ✅ Done |
| `DELETE /devices/{id}/push-token` | Clear token, platform and locale (self only, idempotent), 204 | ✅ Done |
| `GET /push/webpush-key` | Anonymous, `{"publicKey"}` VAPID key (base64url) for `PushManager.subscribe`; 404 when Web Push is not configured | ✅ Done |
| `PUT /groups/{id}/bot-talk` | Bot conversation setting (admin) | ✅ Done |
| `PUT /groups/{id}/mute`, `PUT /mutes/direct/{id}`, `GET /mutes` | Per-device mute (push skip) | ✅ Done |
| `POST /backups` | Upload backup metadata | ✅ Done |
| `GET /backups/{accountId}` | List backups | ✅ Done |
| `DELETE /backups/{accountId}/{backupId}` | Free a backup slot (quota: 3 per account, 8 MiB each, 256 MiB total) | ✅ Done |
| `GET /turn/credentials` | Time-limited TURN credentials | ✅ Done |
| `POST /channels` | Create channel (device must be linked to an account, else 403; 409 over `Channels:MaxOwnedPerDevice` per account) | ✅ Done |
| `GET /channels/mine` | Followed + owned + administered channels with `unreadCount` | ✅ Done |
| `GET /channels/{idOrHandle}` | Public profile (`followerCount`, `isFollowing`, `role` owner/admin/publisher, `status` active/suspended, `suspendedUntil`), never a follower list | ✅ Done |
| `PATCH` / `DELETE /channels/{id}` | Edit (owner/admin) / soft delete (owner, hub `ChannelDeleted`) | ✅ Done |
| `GET /channels/{id}/admins`, `PUT` / `DELETE /channels/{id}/admins/{deviceId}` | Member management (owner only); PUT body `{"role":"admin"\|"publisher"}` optional (none = admin, 400 `invalid_role`); list items carry `role`, `isBot`, `handle`, `displayName` | ✅ Done |
| `POST` / `DELETE /channels/{id}/follow` | Follow / unfollow, idempotent, 204; 403 `channel_suspended` on follow | ✅ Done |
| `POST /channels/{id}/posts` | Publish text/image/poll (owner/admin/publisher); same `postId` again = 200, no second event; 403 `channel_suspended`; bot author over `Channels:MaxBotPostsPerDay` (20) per channel per 24 h -> 429 `bot_post_limit`; post DTO + hub event carry `byBot` | ✅ Done |
| `GET /channels/{id}/posts?before=&after=&limit=` | Feed with reaction/vote totals (follower or member); marks posts as seen; suspended -> 403 `channel_suspended` except for owner/admin/publisher | ✅ Done |
| `DELETE /channels/{id}/posts/{postId}` | Soft delete + tombstone event (publisher: own posts only) | ✅ Done |
| `PUT` / `DELETE /channels/{id}/posts/{postId}/reaction`, `PUT …/vote` | One reaction / vote per device (follower); 422 bad emoji / option index | ✅ Done |
| `POST /channels/{id}/report` | Abuse report (follower, 5 per device per day) `{postId?, reason, category?, contactEmail?, goodFaith?}`, 200 receipt `{reportId, createdAt}`; 400 `invalid_category` / `invalid_contact` / `good_faith_required` | ✅ Done |
| `GET /channels/reports/mine` | This device's reports with outcome (`status` open/dismissed/actioned), newest first, max 100 | ✅ Done |
| `GET /channels/{id}/moderation` | Statements of reasons for owner/admin/publisher (no `dismiss`); owner still reads them after termination | ✅ Done |
| `POST /admin/session` | Operator login (allowlist `Moderation:OperatorAccountIds` + TOTP/backup code) -> 30 min token `scope=moderation`, valid ONLY on `/admin/*` (device token there = 403 `operator_token_required`, operator token elsewhere = 401); whole `/admin` is 404 with an empty allowlist | ✅ Done |
| `GET /admin/summary`, `GET /admin/reports`, `GET /admin/subjects/{channelId}?postId=` | Operator queue grouped by subject (open oldest first, `cursor`/`nextCursor`), case detail with reports and decisions (never reporter ids) | ✅ Done |
| `POST` / `GET /admin/decisions` | Decide (dismiss, remove_post, suspend_channel, terminate_channel, restore_channel) / decision log (`format=csv`) | ✅ Done |
| `GET /admin/channels?q=`, `GET /admin/channels/{id}/attachments/{name}` | Operator channel search (incl. suspended/deleted) and image access | ✅ Done |
| `POST /channels/{id}/attachments`, `GET /channels/{id}/attachments/{name}` | Unencrypted image ≤ `Channels:MaxImageBytes` in Blob container `channel-media` (413 over limit) | ✅ Done |
| `PUT /devices/{primaryId}/device-list` | Primary uploads a new signed device list (version grows; a new companion needs its own `LinkConsent` first, else 409 `device_list_consent_missing`; max 5 companions) | ✅ Done |
| `GET /devices/{id}/device-list` | Signed list `id` is in, as primary or companion; 404 when none | ✅ Done |
| `SignalR /hub` | Message relay, typing, call signaling; channels: `JoinChannels`, `LeaveChannel`, events `ReceiveChannelPost`, `ChannelDeleted`; multi-device: `SendReliableDirectFanout`, `SendReliableGroupFanout` (error `device_list_stale:<ids>`), `LinkOffer` (event carries the primary's `userHandle`), `LinkConsent`, event `DeviceListChanged` | ✅ Done |
| `DELETE /devices/{deviceId}` | GDPR (N09): device forgets itself — keys, queue, memberships, channel activity, push token; 409 `device_is_auditor` if it is an organization's auditor | ✅ Done |
| `DELETE /accounts/{accountId}` | GDPR (N09): account deletion (requires `authKey` proof, irreversible) — links, backups (DB + Blob), owned channels soft-deleted; 409 `account_owns_organization` | ✅ Done |
| `GET /accounts/{accountId}/export` | GDPR (N09): everything the server holds about the account, JSON — see `docs/security/data-subject-rights.md` | ✅ Done |
| `GET /accounts/{id}/mfa` | TOTP MFA status (`enabled`, `confirmedAt`, `backupCodesRemaining`) | ✅ Done |
| `POST /accounts/{id}/mfa/enroll/start` / `.../enroll/confirm` | Start/confirm TOTP enrollment; confirm returns 10 one-time backup codes | ✅ Done |
| `POST /accounts/{id}/mfa/verify` | Verify a TOTP or backup code, returns a short-lived step-up token (`amr=totp`) | ✅ Done |
| `POST /accounts/{id}/mfa/backup-codes/regenerate` | Invalidate + reissue backup codes (requires a step-up token) | ✅ Done |
| `POST /accounts/{id}/mfa/disable` | Disable MFA (requires a valid code) | ✅ Done |

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
   for the wire format). The client verifies the Ed25519 signature over
   identity key + signed pre-key before starting a session
   (`KeyManager.verifyIdentityBundle`). **Known limitations:** no header
   encryption, trust on first use (no safety-number check), the signed pre-key
   is never rotated, Sender Keys for groups pending, multi-device trust is a
   device list signed by the primary device (spec:
   `docs/superpowers/specs/2026-10-13-multi-device-sync-design.md`). Exact primitives and
   parameters, verified against code: `docs/security/crypto-baseline.md` —
   revise it with every change under `calltype_core/lib/crypto`. Document
   limits honestly anywhere user-facing.
3. **Anonymous identity** — device generates UUID + key pair. User Handle
   (`CT-XXXX-XXXX`) for human-readable discovery. QR code for contact exchange.
4. **Backup encryption** — independent passphrase-derived key
   (PBKDF2-HMAC-SHA256, 600k iterations, AES-256-GCM; Argon2id is only used
   server-side for the account auth key).
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
- **Where things stand / how to resume:** `docs/HANDOFF-2026-09-18.md`.
- Beta completion: `docs/superpowers/plans/2026-09-16-beta-zadani.md` (+ `-kontrakty`, `-vyvoj`, `-infrastruktura`); status and evidence in `docs/acceptance/` and `docs/ops/`. Device acceptance (`docs/acceptance/matrix.md`) is mostly NOT_RUN.
- Channels (`docs/superpowers/plans/2026-09-16-channels.md`, §7 overrides §1–§6) and bots (`docs/superpowers/plans/2026-09-17-bots.md`): implemented and deployed; manual acceptance in `docs/acceptance/bots-channels.md` is NOT_RUN.
- **Business mode:** `docs/superpowers/plans/2026-09-18-business-mode.md` (+ `-contracts`). Step 1 is deployed and switched on on beta; acceptance and findings in `docs/acceptance/business-mode.md`. Full-content archive (E03b), four-eyes access (E04), Merkle + qualified timestamps (KB4) and MLS (step 2, `spikes/mls/REPORT.md`) wait for validation with three organizations.
- **Multi-device (spec 1 of 4, live sync):** `docs/superpowers/specs/2026-10-13-multi-device-sync-design.md`, plans `docs/superpowers/plans/2026-10-13-multi-device-sync-1-protocol.md` (core + server) and `2026-10-14-multi-device-sync-2-app.md` (app + bots); manual acceptance in `docs/acceptance/multi-device.md` is NOT_RUN. Companions: no calls, no business conversations, only an empty device can be linked.
- NIS2 / auditability (N01–N10, nothing started): `docs/superpowers/plans/2026-09-18-nis2-auditovatelnost.md`.

## Deploy

Manual, SHA-pinned GitHub Actions workflow `.github/workflows/deploy.yml`
(`gh workflow run deploy.yml -f commit_sha=<full sha> -f confirm_backup=true`):
tests → API + five client builds with manifests → OIDC deploy to the existing
App Service / Static Web App → smoke. It never provisions infrastructure; IaC
lives in `infra/beta-appservice.bicep`. `infra/main.bicep`, `infra/beta-vm.bicep`
and `infra/beta-compose.yml` are historical and must not be deployed.

The repository is PUBLIC permanently (open source, AGPL-3.0, owner decision
2026-11-08). Never flip it back to private and never commit secrets: the old
"public window" (`/gh-actions-public`) procedure is retired. Each deploy still
needs the owner's OK.

Audit-database migrations are NOT applied by the deploy or at startup on beta
(`ConnectionStrings__AuditMigrations` is deliberately unset so the ops password
never sits next to the app password). A change to `CallType.Audit/Migrations`
means a manual step before the deploy — see `docs/HANDOFF-2026-09-18.md`.

## Second brain
@C:/GIT/brain/projects/jay-zmessanger/overview.md
Rozhodnutí a pasti: `C:\GIT\brain\projects\jay-zmessanger\{decisions,gotchas}.md` (čti na vyžádání, ne vždy).
