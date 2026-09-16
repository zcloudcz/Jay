# CallType

CallType is an anonymous-first messaging beta for Android, iOS, web, Windows and macOS. Devices register without a phone number and use a public `CT-XXXX-XXXX` handle. The repository is named `ZMessanger` for historical reasons.

The beta includes direct and group chat, encrypted per-recipient group delivery, attachments up to **256 KiB per file**, voice/video call controls, contacts, and optional account-based encrypted history backup/restore. Platform scaffolding and a CI build matrix are present; this does not mean every platform has passed device testing. See [beta status](docs/beta-status.md).

## Run locally

Install Docker, Flutter 3.41.x and the platform toolchain you want to use. Backend development/tests also require .NET 10.

From the repository root:

```sh
docker compose up --build -d
```

Compose starts the API at `http://localhost:8080`, PostgreSQL and the Azurite backup-storage emulator. Its database migrations run on startup. Development credentials in Compose are for local use.

Start the browser client at the configured CORS origin:

```sh
cd src/client/calltype
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run -d chrome --web-port=8090 --dart-define=API_BASE_URL=http://localhost:8080
```

The web client needs both `web/sqlite3.wasm` and `web/drift_worker.js`. Keep these assets in the published web output; they provide local SQLite storage. Use localhost for development and HTTPS for hosted camera/microphone access.

For another platform, select its Flutter device and provide an API URL reachable from that device. `localhost` on a phone refers to the phone, not the development computer. Configure `API_BASE_URL` at build time; its default is `http://localhost:8080`.

```sh
flutter build web --release --dart-define=API_BASE_URL=https://YOUR_API_HOST
```

## Architecture and security boundaries

| Component | Implementation |
| --- | --- |
| Client | Flutter, Drift/SQLite, platform secure storage |
| API | ASP.NET Core 10, authenticated SignalR, PostgreSQL/EF Core |
| Messaging encryption | Custom Dart X3DH/Double Ratchet implementation; X25519, Ed25519 signed identity/prekey bundles, HKDF and AES-GCM |
| Calls | WebRTC; signaling carries a versioned JSON envelope with a per-call UUID |
| Backups | Client-side PBKDF2-HMAC-SHA256 (600,000 iterations) and AES-256-GCM; encrypted blobs stored server-side |

This is **not official libsignal and has not undergone an independent cryptographic audit**. Message envelopes use version 2 with an authenticated session ID and signed pre-key prologue. Identity keys are pinned on first use; first-contact authenticity still depends on a trusted key comparison. Older unsigned identities and incompatible message/call formats are rejected.

The relay stores message ciphertext before online or offline delivery. It removes ciphertext after the recipient acknowledges local persistence, retaining deduplication metadata until the 30-day expiry. Pending messages can be replayed after reconnect or while connected. Sender/recipient/group metadata remains visible to the relay.

**Local SQLite is not SQLCipher-encrypted.** Message history and ratchet state are readable in local application storage and rely on OS/browser access protection. Platform secure storage holds long-term private key material. Encrypted transport and backups do not encrypt the local history database.

## Services to configure

| Setting | Purpose |
| --- | --- |
| `ConnectionStrings__DefaultConnection` | PostgreSQL connection |
| `ConnectionStrings__BlobStorage` | Azure Blob storage or local Azurite |
| `Jwt__Secret` | Deployment-specific JWT signing secret, at least 32 characters |
| `Database__ApplyMigrationsOnStartup` | Explicit database migration startup switch |
| `Cors__AllowedOrigins__0` | Browser client origin; local Compose uses `http://localhost:8090` |
| `Turn__Urls__0`, `Turn__StunUrls__0` | Reachable TURN/STUN endpoints |
| `Turn__SharedSecret` | Secret matching the TURN server configuration |
| `Push__FcmServiceAccountJson` | Firebase service-account configuration for server push |

Compose does not start a TURN service. Reliable calling across restrictive networks requires a reachable TURN server and configured URLs. Firebase client configuration and notification permissions are required for push; Apple delivery through Firebase also requires APNs credentials/capabilities. Direct APNs relay support is not implemented. Background incoming-call delivery and platform push behavior still require real-device verification.

The [hosted web beta](https://orange-bush-07e1b5803.6.azurestaticapps.net) runs on Azure Static Web Apps Free, with its API at `https://calltype-beta-zahy.azurewebsites.net` on Linux App Service B1. External PostgreSQL, coturn and private Blob backup storage are configured. The API health check, reliable direct/group and offline delivery checks, backup ownership checks, and authenticated UDP/TCP TURN relay tests passed. Real audio/video across separate networks remains unverified.

See the [Azure beta plan](docs/azure-beta-plan.md) for resources and remaining operational checks. The estimate is USD 14-16/month before tax against the USD 20 maximum, not a hard spending guarantee. PostgreSQL currently encrypts traffic with `SSL Mode=Require` without verifying the server certificate. Earlier VM templates are superseded.

## Verification and builds

Verified locally on 2026-09-13: **108 backend tests passed, 0 skipped, and 120 Flutter tests passed**; release builds succeeded for web, Android (107.9 MiB APK) and Windows (complete runtime ZIP). Two browser identities exchanged encrypted direct messages in both directions, including diacritics, with history preserved after reload. Offline delivery after reopening the recipient was observed once. Group creation and encrypted delivery to the selected member were verified. Flutter analysis reported no issues. The final incremental Android rebuild also succeeded. Apple builds and native-device behavior remain unverified; see [beta status](docs/beta-status.md) for artifact paths and remaining checks.

The current Android APK and `calltype-windows-azure-beta.zip` were rebuilt with the Azure API URL. Two real Flutter browser clients exchanged encrypted Czech direct messages in both directions through the hosted API; both messages persisted after reloading the public web client. Hosted web and API checks do not replace native-device acceptance or Apple builds.

```sh
dotnet test src/server/CallType.Api.Tests --configuration Release
```

The backend integration suite starts PostgreSQL and Azurite through Testcontainers, so Docker must be running. From `src/client/calltype`:

```sh
flutter analyze
flutter test
```

[CI](.github/workflows/ci.yml) gates five platform artifact builds on backend tests and Flutter analysis/tests. Set the repository variable `CALLTYPE_API_BASE_URL` before distributing CI artifacts. iOS artifacts are unsigned; macOS distribution signing/notarization and store publication remain separate release steps. CI preparation does not establish that Apple builds have run successfully.

Historical design material remains in [docs/superpowers/specs](docs/superpowers/specs/). [CLAUDE.md](CLAUDE.md) and [infra](infra/) contain earlier development/deployment material; current implementation and [beta status](docs/beta-status.md) take precedence over older feature claims.
