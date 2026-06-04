# CallType — Design Specification

## Overview

Multiplatform end-to-end encrypted messaging application. Anonymous-first with optional registration for cloud backup. Voice and video calls via WebRTC. Simple, minimalist UI.

**Target platforms:** iOS, Android, Web (Flutter single codebase)

## Requirements

### Functional

- **Anonymous access** — no registration required. Device generates unique ID + Identity Key on first launch.
- **Optional registration** — email + passphrase. Enables cloud backup and multi-device sync.
- **1:1 chat** — text messages, images, files, voice messages.
- **Group chat** — up to 256 members, admin roles (create/invite/remove).
- **Voice calls** — 1:1 via WebRTC P2P.
- **Video calls** — 1:1 via WebRTC P2P.
- **Group calls** — via SFU (future phase, not MVP).
- **E2E encryption** — Signal Protocol (X3DH + Double Ratchet). Server never sees plaintext.
- **Cloud backup** — registered users only. Client-side encrypted (passphrase-derived key). Incremental.
- **App lock** — PIN (4-6 digits) or biometrics (FaceID/TouchID/fingerprint).
- **Contact discovery** — QR code scan or invite link. No phone number required.
- **Push notifications** — FCM (Android) + APNs (iOS). Notification content encrypted; server sends "new message" trigger only.

### Non-Functional

- **Offline-first** — messages stored locally in encrypted SQLite. Delivered when recipient comes online.
- **Store-and-forward** — server holds encrypted message blobs until delivered, then deletes.
- **Latency** — message delivery < 500ms when both parties online.
- **Scalability** — architecture supports horizontal scaling via Azure Container Apps replicas.
- **Privacy** — server stores minimum metadata: public keys, device tokens, group membership. No message content, no contact lists, no usage analytics.

## Technology Stack

| Layer | Technology | Notes |
|-------|-----------|-------|
| **Mobile + Web client** | Flutter (Dart) | Single codebase: iOS, Android, Web |
| **Backend API** | ASP.NET Core 8 (minimal API) | REST endpoints for registration, key exchange, backup |
| **Real-time messaging** | SignalR (WebSocket) | Message relay, typing indicators, presence, call signaling |
| **Database** | PostgreSQL (Azure Database) | User metadata, key bundles, encrypted message queue, group membership |
| **Local storage** | SQLite + `sqlcipher` | Encrypted local message store on device |
| **File storage** | Azure Blob Storage | Encrypted attachments and backups |
| **E2EE** | libsignal (Rust) | FFI on mobile, WASM on web |
| **Voice/Video** | WebRTC via `flutter_webrtc` | P2P media, SRTP encryption |
| **STUN/TURN** | DeskShare.Stun + DeskShare.Turn | Shared infra from `C:\GIT\ZCLOUD\RemoteDesktopNet` — .NET 8, RFC 5389/5766 |
| **Push** | FCM (Android) + APNs (iOS) | Server-side relay service |
| **Hosting** | Azure Container Apps | Persistent WebSocket support, auto-scaling, managed TLS |
| **CI/CD** | GitHub Actions | Build, test, deploy pipeline |

## Architecture

### High-Level

```
┌─────────────────────────────────────────────────────────┐
│  CLIENTS (Flutter)                                      │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐              │
│  │ iOS      │  │ Android  │  │ Web      │              │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘              │
│       └──────────┬───┴─────────────┘                    │
│                  │                                       │
│       HTTPS (REST) + WebSocket (SignalR)                 │
│       WebRTC (P2P media, signaled via SignalR)           │
└──────────────────┬───────────────────────────────────────┘
                   │
┌──────────────────┼───────────────────────────────────────┐
│  AZURE           │                                       │
│                  │                                       │
│  ┌───────────────▼──────────────────┐                    │
│  │  Azure Container Apps            │                    │
│  │  ┌──────────────┐ ┌───────────┐  │                    │
│  │  │ API Service  │ │ SignalR   │  │                    │
│  │  │ (REST)       │ │ Hub      │  │                    │
│  │  └──────┬───────┘ └─────┬─────┘  │                    │
│  └─────────┼───────────────┼────────┘                    │
│            │               │                             │
│  ┌─────────▼───────────────▼────────┐                    │
│  │  PostgreSQL                      │                    │
│  │  - user_devices (id, public_key) │                    │
│  │  - key_bundles (pre-keys)        │                    │
│  │  - message_queue (encrypted)     │                    │
│  │  - groups (membership, metadata) │                    │
│  └──────────────────────────────────┘                    │
│                                                          │
│  ┌───────────────┐  ┌──────────────────────────────┐     │
│  │ Azure Blob    │  │ DeskShare STUN/TURN          │     │
│  │ Storage       │  │ (from RemoteDesktopNet)      │     │
│  │ - attachments │  │ STUN :3478 / TURN :3479      │     │
│  │ - backups     │  │ Shared Container App          │     │
│  └───────────────┘  └──────────────────────────────┘     │
│                                                          │
│  ┌───────────────┐                                       │
│  │ Push Relay    │  FCM + APNs                           │
│  └───────────────┘                                       │
└──────────────────────────────────────────────────────────┘
```

### Server Components

**API Service (REST):**
- `POST /devices` — register device (upload Identity Key + Pre-Keys)
- `GET /devices/{id}/key-bundle` — fetch key bundle for X3DH handshake
- `POST /accounts` — register account (email + passphrase hash)
- `POST /accounts/login` — authenticate, link device to account
- `GET /accounts/devices` — list linked devices
- `POST /backups` — upload encrypted backup chunk
- `GET /backups` — list available backups
- `GET /backups/{id}` — download backup chunk
- `POST /groups` — create group
- `PUT /groups/{id}/members` — manage group membership

**SignalR Hub:**
- `SendMessage(recipientDeviceId, encryptedPayload)` — relay encrypted message
- `SendGroupMessage(groupId, encryptedPayloads)` — relay to group members' devices
- `TypingIndicator(conversationId)` — typing status
- `CallSignal(targetDeviceId, signalType, payload)` — WebRTC signaling (offer/answer/ICE)
- `Presence` — online/offline/last seen (opt-in)

**Message Queue (store-and-forward):**
- Incoming message → persist to `message_queue` table (encrypted blob + recipient device ID + timestamp)
- Recipient connects → deliver queued messages → delete from queue
- TTL: 30 days. Undelivered messages expire and are deleted.

### Client Architecture (Flutter)

```
lib/
├── main.dart
├── app/
│   ├── router.dart              # GoRouter navigation
│   └── theme.dart               # Material Design 3 theme
├── core/
│   ├── crypto/
│   │   ├── signal_protocol.dart # libsignal FFI/WASM wrapper
│   │   ├── key_manager.dart     # Identity/Pre-Key generation & storage
│   │   └── backup_crypto.dart   # Argon2 key derivation + AES-GCM
│   ├── network/
│   │   ├── api_client.dart      # REST API client (dio)
│   │   ├── signalr_client.dart  # SignalR connection manager
│   │   └── webrtc_manager.dart  # WebRTC session lifecycle
│   ├── storage/
│   │   ├── local_db.dart        # SQLCipher encrypted database
│   │   └── secure_storage.dart  # flutter_secure_storage (keys, PIN)
│   └── auth/
│       └── app_lock.dart        # PIN + biometric gate (local_auth)
├── features/
│   ├── onboarding/              # Device setup, QR display
│   ├── chat_list/               # Conversation list
│   ├── chat/                    # Message thread (1:1 and group)
│   ├── contacts/                # QR scanner, invite links, contact list
│   ├── calls/                   # Voice/video call UI
│   ├── groups/                  # Group creation, member management
│   ├── backup/                  # Backup settings, restore flow
│   └── settings/                # App lock, account, linked devices
└── shared/
    ├── widgets/                 # Reusable UI components
    └── models/                  # Data models
```

## E2E Encryption Protocol

### Signal Protocol Implementation

**Key hierarchy:**
- **Identity Key Pair** — long-term, generated once per device. Ed25519.
- **Signed Pre-Key** — medium-term, rotated weekly. Signed by Identity Key.
- **One-Time Pre-Keys** — single-use, batch of 100. Replenished when low.

**Session establishment (X3DH):**

1. Alice fetches Bob's Key Bundle from server (Identity Key + Signed Pre-Key + One-Time Pre-Key)
2. Alice verifies Signed Pre-Key signature
3. Alice performs X3DH → shared secret
4. Alice initializes Double Ratchet with shared secret
5. Alice sends first message (encrypted) + her ephemeral public key
6. Bob receives → performs X3DH from his side → initializes Double Ratchet
7. Subsequent messages: Double Ratchet advances — new symmetric key per message

**Group chat encryption (Sender Keys):**

1. Each member generates a Sender Key (symmetric)
2. Sender Key distributed to all group members via their 1:1 E2EE sessions
3. Group messages encrypted with sender's Sender Key
4. On member removal: all remaining members rotate their Sender Keys
5. On member addition: existing members send their current Sender Keys to new member

**Implementation:** `libsignal` Rust library.
- Mobile (iOS/Android): Rust → C ABI → Dart FFI (`dart:ffi`)
- Web: Rust → WASM → Dart JS interop

## Identity and Discovery

### Device Registration (Anonymous)

1. App generates `DeviceID` (UUID v4)
2. App generates Identity Key Pair (Ed25519)
3. App generates batch of Pre-Keys
4. App uploads to server: `DeviceID` + public Identity Key + Pre-Keys
5. Server assigns short **User Handle**: `CT-XXXX-XXXX` (8 alphanumeric chars)
6. App displays QR code: `calltype://contact/{handle}/{identity-key-fingerprint}`

### Contact Addition

- **QR scan** — in-person. Camera scans QR → verifies fingerprint → adds contact.
- **Invite link** — share `https://calltype.app/c/{handle}`. Recipient opens → app resolves handle → fetches Key Bundle → TOFU.
- **Safety numbers** — derived from both parties' Identity Keys. Displayed in chat settings for manual verification.

### Account Registration (Optional Upgrade)

1. User provides email + creates passphrase
2. Client derives auth key from passphrase (Argon2id) — sent to server for authentication
3. Client derives separate backup key from passphrase (Argon2id, different salt) — never sent to server
4. Server links DeviceID to Account
5. Enables: cloud backup, multi-device linking

### Multi-Device (Registered Only)

- Each device has its own Identity Key Pair
- Messages encrypted separately for each of user's devices
- Server maintains `account → [device_id, device_id, ...]` mapping
- New device linking: QR scan from existing device (transfers account link, not keys)

## Voice and Video Calls

### Signaling (via SignalR)

```
Alice                    Server (SignalR)              Bob
  │                           │                         │
  │── CallSignal(offer) ─────►│── CallSignal(offer) ───►│
  │                           │                         │
  │◄── CallSignal(answer) ────│◄── CallSignal(answer) ──│
  │                           │                         │
  │── CallSignal(ice) ───────►│── CallSignal(ice) ─────►│
  │◄── CallSignal(ice) ───────│◄── CallSignal(ice) ─────│
  │                           │                         │
  │◄═══════════ WebRTC P2P (SRTP) ═════════════════════►│
```

### STUN/TURN Infrastructure

Shared with `RemoteDesktopNet` (DeskShare) project at `C:\GIT\ZCLOUD\RemoteDesktopNet`.

- **DeskShare.Stun** — RFC 5389 STUN server, UDP port 3478
- **DeskShare.Turn** — RFC 5766 TURN server, UDP port 3479, long-term credentials (HMAC-SHA1)

**Integration plan:**
- Extract STUN/TURN as shared NuGet packages or deploy as shared Azure Container App
- CallType API issues time-limited TURN credentials to clients via REST endpoint
- `TurnAuthenticator` extended to support CallType device authentication
- Existing OpenTelemetry/Prometheus monitoring pipeline reused

**Client ICE configuration:**
```dart
final iceServers = [
  {'urls': 'stun:turn.calltype.app:3478'},
  {
    'urls': 'turn:turn.calltype.app:3479',
    'username': timeBasedUsername,
    'credential': hmacCredential,
  },
];
```

### Group Calls (Future Phase — Not MVP)

- SFU (Selective Forwarding Unit) — mediasoup or custom .NET implementation
- Each participant sends one stream to SFU, SFU forwards to others
- Transport encryption (SRTP) in MVP phase; full E2EE for group calls deferred (requires Insertable Streams API)

## Cloud Backup

### Architecture

```
Client                                          Azure Blob Storage
  │                                               │
  │  1. Serialize new messages + attachments       │
  │  2. Derive backup key (Argon2id + passphrase)  │
  │  3. Encrypt with AES-256-GCM                   │
  │  4. Upload encrypted chunks                    │
  │────── PUT /backups (encrypted blob) ──────────►│
  │                                               │
  │  Restore:                                      │
  │  1. Login on new device                        │
  │  2. Enter passphrase                           │
  │  3. Download + decrypt                         │
  │◄───── GET /backups/{id} ──────────────────────│
```

### Backup Details

| Aspect | Design |
|--------|--------|
| **Encryption** | AES-256-GCM. Key derived from user passphrase via Argon2id (separate salt from auth key). |
| **Content** | Messages, attachments, contacts, group metadata. NOT E2EE session keys (re-established on restore). |
| **Schedule** | Automatic (configurable: daily/weekly/manual). |
| **Incremental** | Yes — manifest tracks last backed-up message ID. Only new messages backed up. |
| **Storage** | Azure Blob Storage: `backups/{account_id}/{timestamp}.enc` + `manifest.enc` |
| **Quota** | Configurable per plan. Free tier: 1 GB. |
| **Restore** | New device → login → enter passphrase → download manifest → download chunks → decrypt → import to local SQLite. |
| **Anonymous users** | No backup. Loss of device = loss of messages. Clearly communicated in onboarding. |

### Backup Key vs App Lock PIN

These are independent mechanisms:
- **App Lock PIN/Biometrics** — protects access to the app on the device. Stored locally in Secure Enclave / Keystore.
- **Backup Passphrase** — protects backup in the cloud. Used to derive encryption key. Never sent to server.

## Local Security (App Lock)

- **PIN** — 4-6 digits, stored as hash in `flutter_secure_storage` (backed by iOS Keychain / Android Keystore)
- **Biometrics** — `local_auth` Flutter plugin (FaceID, TouchID, Android fingerprint)
- **Auto-lock** — configurable timeout (immediate, 1 min, 5 min, 30 min)
- **Failed attempts** — after N failures (configurable), optionally wipe local encryption keys
- **Implementation** — PIN/biometrics unlock a local master key that decrypts the SQLCipher database

## UI Screens

Minimalist Material Design 3. Dark and light mode. No animations beyond standard transitions.

| Screen | Purpose |
|--------|---------|
| **Onboarding** | Generate device ID, display QR code and User Handle, explain anonymous model |
| **Chat List** | Conversations sorted by last activity, unread badge, last message preview (decrypted locally) |
| **Chat Detail** | Message bubbles, text input, attachment picker (image/file/voice), reply/forward |
| **Contacts** | QR scanner, invite link sharing, contact list with online status |
| **Group Create** | Select members, set group name and avatar |
| **Call Screen** | Voice/video UI — mute, speaker, camera toggle, end call |
| **Settings** | App lock config, backup settings, linked devices, account (register/login), about |
| **Safety Numbers** | Display verification code for contact's Identity Key |

## Database Schema (PostgreSQL — Server)

```sql
-- Devices (anonymous identity)
CREATE TABLE devices (
    device_id       UUID PRIMARY KEY,
    user_handle     VARCHAR(10) UNIQUE NOT NULL,
    identity_key    BYTEA NOT NULL,
    signed_pre_key  BYTEA NOT NULL,
    push_token      TEXT,
    push_platform   VARCHAR(10), -- 'fcm' | 'apns' | null (web)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at    TIMESTAMPTZ
);

-- One-time pre-keys (consumed on use)
CREATE TABLE one_time_pre_keys (
    id              BIGSERIAL PRIMARY KEY,
    device_id       UUID NOT NULL REFERENCES devices(device_id),
    key_id          INTEGER NOT NULL,
    public_key      BYTEA NOT NULL,
    UNIQUE(device_id, key_id)
);

-- Accounts (optional registration)
CREATE TABLE accounts (
    account_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email           VARCHAR(255) UNIQUE NOT NULL,
    auth_key_hash   BYTEA NOT NULL, -- Argon2id hash
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Link devices to accounts (multi-device)
CREATE TABLE account_devices (
    account_id      UUID NOT NULL REFERENCES accounts(account_id),
    device_id       UUID NOT NULL REFERENCES devices(device_id),
    linked_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, device_id)
);

-- Message queue (store-and-forward, encrypted blobs)
CREATE TABLE message_queue (
    id              BIGSERIAL PRIMARY KEY,
    recipient_id    UUID NOT NULL REFERENCES devices(device_id),
    sender_id       UUID NOT NULL,
    encrypted_body  BYTEA NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at      TIMESTAMPTZ NOT NULL DEFAULT now() + INTERVAL '30 days'
);
CREATE INDEX idx_message_queue_recipient ON message_queue(recipient_id, created_at);

-- Groups
CREATE TABLE groups (
    group_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name_encrypted  BYTEA, -- encrypted by group creator, optional server-side
    created_by      UUID NOT NULL REFERENCES devices(device_id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE group_members (
    group_id        UUID NOT NULL REFERENCES groups(group_id),
    device_id       UUID NOT NULL REFERENCES devices(device_id),
    role            VARCHAR(10) NOT NULL DEFAULT 'member', -- 'admin' | 'member'
    joined_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (group_id, device_id)
);

-- Backup metadata
CREATE TABLE backups (
    id              BIGSERIAL PRIMARY KEY,
    account_id      UUID NOT NULL REFERENCES accounts(account_id),
    blob_path       TEXT NOT NULL, -- Azure Blob Storage path
    size_bytes      BIGINT NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

## Local Database Schema (SQLite + SQLCipher — Client)

```sql
-- Contacts
CREATE TABLE contacts (
    device_id       TEXT PRIMARY KEY,
    user_handle     TEXT NOT NULL,
    display_name    TEXT,
    identity_key    BLOB NOT NULL,
    verified        INTEGER NOT NULL DEFAULT 0, -- safety number verified
    added_at        TEXT NOT NULL
);

-- Conversations
CREATE TABLE conversations (
    id              TEXT PRIMARY KEY, -- device_id for 1:1, group_id for group
    type            TEXT NOT NULL, -- 'direct' | 'group'
    title           TEXT, -- group name
    last_message_at TEXT,
    unread_count    INTEGER NOT NULL DEFAULT 0
);

-- Messages
CREATE TABLE messages (
    id              TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL REFERENCES conversations(id),
    sender_id       TEXT NOT NULL,
    body            TEXT, -- decrypted plaintext
    type            TEXT NOT NULL DEFAULT 'text', -- 'text' | 'image' | 'file' | 'voice'
    attachment_path TEXT, -- local file path for attachments
    status          TEXT NOT NULL DEFAULT 'sent', -- 'sending' | 'sent' | 'delivered' | 'read'
    created_at      TEXT NOT NULL,
    received_at     TEXT
);
CREATE INDEX idx_messages_conversation ON messages(conversation_id, created_at);

-- Signal Protocol session state
CREATE TABLE signal_sessions (
    address         TEXT PRIMARY KEY, -- device_id
    session_data    BLOB NOT NULL
);

-- Backup tracking
CREATE TABLE backup_state (
    key             TEXT PRIMARY KEY,
    value           TEXT NOT NULL
);
```

## Security Considerations

- **Server sees only:** device IDs, public keys, encrypted message blobs, group membership IDs, push tokens.
- **Server never sees:** message content, contact names, group names (encrypted client-side), backup content.
- **Key rotation:** Signed Pre-Keys rotated weekly. One-Time Pre-Keys replenished when < 20 remaining.
- **Forward secrecy:** Double Ratchet ensures compromise of one message key doesn't reveal past/future messages.
- **Backup security:** Independent passphrase-derived key (Argon2id). Brute-force resistant.
- **Transport:** All client↔server communication over TLS 1.3.
- **Local:** SQLCipher AES-256 encryption. Master key in platform Secure Enclave / Keystore.
- **TURN credentials:** Time-limited (validity window), HMAC-SHA1 signed. No permanent credentials on client.

## MVP Scope

### In MVP

- Anonymous device registration + User Handle + QR
- 1:1 E2EE chat (text, images, files)
- Group E2EE chat (up to 50 members for MVP)
- 1:1 voice and video calls (WebRTC P2P)
- App lock (PIN + biometrics)
- Push notifications
- Optional account registration
- Cloud backup (registered users)
- Web client

### Post-MVP

- Group voice/video calls (SFU)
- Disappearing messages
- Message reactions/replies
- Voice messages
- Link previews
- Desktop client (Flutter desktop or Electron)
- Multi-device for anonymous users (device-to-device sync)
- E2EE group calls (Insertable Streams)
- Read receipts (opt-in)
- Status/stories

## Project Dependencies

| Dependency | Source |
|-----------|--------|
| STUN/TURN servers | `C:\GIT\ZCLOUD\RemoteDesktopNet` — DeskShare.Stun + DeskShare.Turn |
| libsignal | https://github.com/nicegram/libsignal-protocol — official Signal Foundation Rust library. Dart bindings via FFI (mobile) and WASM (web) to be built as part of this project. |
| flutter_webrtc | pub.dev package |
| local_auth | pub.dev package |
| flutter_secure_storage | pub.dev package |
| sqlcipher | pub.dev `sqflite_sqlcipher` package |
| SignalR client | pub.dev `signalr_netcore` package |
