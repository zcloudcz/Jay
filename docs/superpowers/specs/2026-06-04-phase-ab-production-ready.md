# CallType Phase A+B — Production Ready

## Goal

Transform CallType from a working scaffold (102 tests, all endpoints + UI implemented with placeholder crypto) into a production-deployable E2E encrypted messenger.

## Scope

### Phase A: Functional E2E

1. **JWT Authentication** — protect all endpoints and SignalR hub
2. **Real E2EE** — compile libsignal, wire into chat flow
3. **AES-256-GCM backup encryption** — replace placeholder base64
4. **Azure Blob Storage** — real file upload/download for backups

### Phase B: Production Infrastructure

5. **Docker + docker-compose** — containerized API + PostgreSQL
6. **Azure Container Apps deployment** — Bicep templates
7. **CI/CD** — GitHub Actions (build, test, deploy)
8. **STUN/TURN deployment** — shared with RemoteDesktopNet
9. **Push notifications** — FCM + APNs client token registration
10. **TLS, CORS, rate limiting** — production hardening

---

## 1. JWT Authentication

### Design

Device-based auth (not user/password — anonymous devices need tokens too).

**Token flow:**
1. Device registers via `POST /devices` → receives `deviceId` + `userHandle`
2. Device calls `POST /auth/token` with `deviceId` + signed challenge (HMAC of deviceId with device's private identity key)
3. Server verifies signature against stored public identity key
4. Server issues JWT: `{ sub: deviceId, handle: userHandle, iat, exp }`
5. Token expires in 24h, refresh via `POST /auth/refresh`

**Simplified MVP approach (Phase A):**
Since libsignal integration is complex and we need auth working first, use a simpler scheme:
1. `POST /devices` returns a `deviceSecret` (random 32-byte token, stored hashed on server)
2. `POST /auth/token` accepts `{ deviceId, deviceSecret }` → returns JWT
3. All endpoints require `Authorization: Bearer <jwt>` (except `POST /devices`, `GET /health`)
4. SignalR hub validates JWT from query string or header
5. Hub derives `deviceId` from JWT claims (not from query parameter)

**Later (after libsignal):** Replace deviceSecret with proper cryptographic challenge-response.

**Server changes:**
- Add `DeviceSecretHash` (byte[]) column to Device entity
- New `AuthEndpoints.cs` with token/refresh endpoints
- `JwtService.cs` — generate/validate JWTs (HMAC-SHA256, configurable secret)
- Add `[Authorize]` to all endpoint groups except device registration and health
- Update MessengerHub to read deviceId from JWT claims
- Add JWT config to appsettings.json

**Client changes:**
- Store deviceSecret in SecureStorage on registration
- ApiClient: add token storage, auto-attach Bearer header, auto-refresh on 401
- SignalR client: pass token in connection options

### Tests
- Register → get token → access protected endpoint (200)
- Access without token → 401
- Access with expired token → 401
- SignalR connect with valid token
- SignalR connect without token → rejected

---

## 2. Real E2EE (libsignal)

### Design

**Problem:** libsignal-protocol Rust crate compilation to all targets (Android arm64/armv7/x86_64, iOS, WASM) is a multi-day build system task requiring:
- cargo-ndk for Android
- cargo-lipo for iOS
- wasm-pack for Web
- CI cross-compilation setup

**Pragmatic MVP approach:** Use a pure-Dart Signal Protocol implementation instead of Rust FFI.

Package: `signal_protocol_dart` or implement core primitives using `pointycastle`:
- X25519 key exchange (Curve25519)
- Ed25519 signatures
- HKDF key derivation
- AES-256-CBC + HMAC-SHA256 for Double Ratchet message encryption
- X3DH handshake
- Double Ratchet state machine

**If no suitable Dart package exists:** Implement a simplified but correct E2EE layer:
1. X25519 key agreement (via `cryptography` Dart package)
2. HKDF-SHA256 for key derivation
3. AES-256-GCM for message encryption
4. Pre-key exchange matching X3DH flow

**Files:**
- Replace `signal_protocol.dart` placeholder with real crypto
- Update `session_manager.dart` with real encrypt/decrypt
- Update `key_manager.dart` to generate real Curve25519 keys
- Update `chat_controller.dart` to call real encrypt before send, decrypt on receive
- Server already treats messages as opaque blobs — no server changes needed

### Tests
- Key pair generation produces valid Curve25519 keys
- X3DH handshake between two parties produces shared secret
- Encrypt → decrypt roundtrip
- Different sessions produce different ciphertexts
- Tampered ciphertext fails decryption

---

## 3. AES-256-GCM Backup Encryption

### Design

Replace PBKDF2 + base64 placeholder with real encryption:
- Key derivation: Argon2id (via `cryptography` package) or keep PBKDF2-SHA256 with 600k iterations
- Encryption: AES-256-GCM (via `pointycastle` or `encrypt` package)
- Format: `[16-byte salt][12-byte nonce][ciphertext][16-byte GCM tag]`

**Files:**
- Update `backup_crypto.dart` — add `encrypt(key, plaintext)` and `decrypt(key, ciphertext)`
- Update `backup_controller.dart` — use real encryption

---

## 4. Azure Blob Storage

### Design

Wire real upload/download in BackupEndpoints:
- `POST /backups/{accountId}` — accept multipart form upload, store to Azure Blob
- `GET /backups/{accountId}/{backupId}` — stream download from Azure Blob
- Client: upload encrypted backup bytes, download + decrypt on restore

**Server:** Already has `BlobServiceClient` reference in csproj. Wire into endpoints.
**Client:** Use dio for multipart upload.

---

## 5. Docker + docker-compose

### Design

```yaml
# docker-compose.yml
services:
  api:
    build: src/server/CallType.Api
    ports: ["8080:8080"]
    environment:
      - ConnectionStrings__DefaultConnection=Host=db;Database=calltype;...
      - Jwt__Secret=...
    depends_on: [db]
  db:
    image: postgres:17-alpine
    volumes: [pgdata:/var/lib/postgresql/data]
    environment:
      - POSTGRES_DB=calltype
      - POSTGRES_PASSWORD=...
```

Update existing Dockerfile. Add health check.

---

## 6. Azure Container Apps (Bicep)

### Design

Bicep templates for:
- Container App (API) with SignalR sticky sessions
- Azure Database for PostgreSQL Flexible Server
- Azure Blob Storage account
- Container App Environment with Log Analytics

---

## 7. CI/CD (GitHub Actions)

### Design

Two workflows:
- `ci.yml` — on PR: build, test (backend + Flutter), lint
- `deploy.yml` — on push to main: build container, push to ACR, deploy to Azure

---

## 8. STUN/TURN Deployment

### Design

Deploy DeskShare.Stun + DeskShare.Turn as shared Container App:
- Reference RemoteDesktopNet's existing Dockerfile/deployment
- Configure shared secret matching CallType's `Turn:SharedSecret`
- UDP ports 3478 (STUN) + 3479 (TURN)

---

## 9. Push Notifications

### Design

**Server:**
- `PushNotificationService` already exists (placeholder FCM/APNs)
- Wire real FCM HTTP v1 API (add `FirebaseAdmin` NuGet or raw HTTP)
- Wire real APNs HTTP/2 (add `dotnet-apns` NuGet or raw HTTP)

**Client:**
- Add `firebase_messaging` Flutter package
- Register FCM token on startup, send to server via `PUT /devices/{id}/push-token`
- Handle incoming notifications (show local notification when app in background)

---

## 10. TLS, CORS, Rate Limiting

### Design

- CORS: allow Flutter web origin only
- Rate limiting: `Microsoft.AspNetCore.RateLimiting` — fixed window, 100 req/min per IP for API, 10 req/min for auth endpoints
- TLS: handled by Azure Container Apps (managed certificates)
- Input size limits: 1MB max request body
