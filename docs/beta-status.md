# Beta status

Scope: Android, iOS, web, Windows and macOS beta. This document distinguishes implemented behavior from executed release validation. Local evidence was collected on 2026-09-13; hosted deployment evidence was updated on 2026-09-14.

## Implemented

- Anonymous device registration, public handles, contacts and onboarding.
- Pairwise encrypted direct/group messages, authenticated group fan-out, local inbox persistence and UUID deduplication.
- Durable server queue for online/offline delivery, recipient acknowledgement, reconnect and explicit pending-message replay.
- Encrypted file attachments with a 256 KiB raw-file limit.
- Voice/video controls, explicit incoming-call acceptance, media cleanup, timeout and call UUID isolation.
- Optional account association and encrypted history backup/restore; restored history is not a transfer of device identity or live cryptographic sessions.
- Platform runner projects and CI artifact build entries for all five targets.

## Evidence available

- Final backend integration suite: **108 passed, 0 skipped**. Coverage includes concurrent retries, acknowledgement ownership, replay, group authorization, accounts/backups and preservation of queued data during migration.
- Web release build succeeded. Two real browser identities exchanged encrypted direct messages in both directions, including Czech diacritics; history persisted after reload. With the recipient closed, a queued message arrived once after reopening. A group named `Beta ověření` was created with a selected member, and that member received and decrypted its encrypted group message.
- Android release APK built successfully: `src/client/calltype/build/app/outputs/flutter-apk/app-release.apk` (113,131,723 bytes; 107.9 MiB), including the final incremental rebuild.
- Windows release built successfully and the complete runtime was packaged as `src/client/calltype/build/calltype-windows-beta.zip` (24,377,109 bytes).
- Five focused WebRTC tests passed: cancellation during media acquisition, fast answer/ICE ordering, replacement-call isolation, stale same-peer hangup rejection and incoming UUID capture/legacy rejection.
- **120 Flutter tests passed**. Final Flutter analysis completed with no issues (exit 0).
- CI YAML was parsed and its five-platform matrix checked locally. Hosted CI and Apple builds/device tests have not been executed in this environment.
- The Testcontainers dependency update removed the reported transitive SSH.NET advisory from the package audit at the time checked.

The API is deployed at `https://calltype-beta-zahy.azurewebsites.net` with a healthy `/health` endpoint. The [hosted web beta](https://orange-bush-07e1b5803.6.azurestaticapps.net) is deployed on Static Web Apps Free. PostgreSQL authentication from Azure passed over TLS 1.3, three migrations were applied, and private Blob storage is configured.

Hosted HTTP/SignalR checks passed for reliable direct/group delivery, offline replay, acknowledgements and account linking. An opaque 60-byte AES-GCM backup passed upload/list/download equality and foreign-account HTTP 403 checks. Authenticated coturn UDP and TCP relay tests each delivered 10 of 10 messages. This is protocol/API evidence; real client audio/video and Flutter backup restore still need acceptance checks.

Two real Flutter browser clients exchanged encrypted Czech direct messages in both directions through the hosted API. Reloading the public Static Web Apps client retained both decrypted messages in its local database. The temporary local test client was stopped and its CORS origin removed after verification; the broader local browser checks above remain separate evidence.

Android `src/client/calltype/build/app/outputs/flutter-apk/app-release.apk` and Windows `src/client/calltype/build/calltype-windows-azure-beta.zip` were rebuilt with the actual Azure API URL. The earlier artifact sizes above describe the local builds, not these Azure builds. Build success does not establish device-level validation or signed distribution readiness.

## Remaining release checks

- Exercise Android/Windows artifacts on devices; run macOS/iOS builds and device checks on Apple infrastructure. Complete signing and distribution setup.
- Validate reconnect, group membership changes, backup restore and attachment limits on each target.
- Exercise real audio/video through TURN across separate/restrictive networks; verify microphone/camera permissions, rapid redial and app lifecycle behavior. UDP/TCP relay protocol checks have passed.
- Configure Firebase/APNs and verify notifications/background behavior on real devices. Provider configuration is currently absent.
- Complete operational checks in the [Azure beta plan](azure-beta-plan.md): certificate verification for PostgreSQL, database restoration, included bandwidth and workload quotas. Linux B1, Static Web Apps Free and private Blob storage are deployed, with PostgreSQL and coturn on the existing server. The **USD 14-16/month before tax** estimate is not a guaranteed **USD 20 cap**. Earlier VM templates are superseded; no purchased domain is required.

## Security and compatibility limits

Messaging uses a custom Dart implementation, not official libsignal, and has no independent security audit. Version-2 envelopes authenticate session routing and the signed pre-key prologue; first-contact trust remains TOFU. Call signaling uses `{v: 1, callId, payload}` JSON and rejects legacy raw SDP. Older unsigned device identities are incompatible with this beta.

Local history and ratchet state use ordinary SQLite, not SQLCipher; local confidentiality relies on OS/browser storage protections. Backup encryption uses PBKDF2-HMAC-SHA256 and AES-GCM. The relay can see delivery metadata. Ciphertext expires after 30 days, and acknowledged delivery IDs are retained only within that expiry window.

The source default API endpoint remains local development infrastructure. The deployed web and current Azure Android/Windows artifacts explicitly compile the Azure API URL. Future builds must also supply it; do not distribute localhost-configured artifacts as a remotely usable beta. PostgreSQL currently uses `SSL Mode=Require`, which encrypts the connection without verifying the server certificate.
