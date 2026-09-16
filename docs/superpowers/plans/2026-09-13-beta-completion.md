# CallType beta completion

Goal agreed with user: Android, iOS, web, Windows and macOS beta. Retain Flutter, Provider, ASP.NET Core and anonymous device identities. No store publication or cloud provisioning is implied.

## Acceptance and execution

- [ ] Startup: unregistered devices see onboarding; successful registration activates the real device identity and authenticated SignalR; reconnect has visible failure/retry states. API URL is a build setting.
- [ ] Delivery: persist encrypted messages before relay, preserve sender UUID and group context, acknowledge only after durable client storage, deduplicate replay, retain encrypted outbox for retry. Test disconnect, duplicate delivery, unauthorized acknowledgements.
- [ ] Groups: create through server API, check membership, encrypt per recipient using established pairwise sessions, preserve group routing offline. Test real local SQLite and fake transport boundaries.
- [ ] Accounts/backups: prove account ownership before linking, authorize backup access, upload to actual backup endpoint, validate and atomically restore decrypted data. Test wrong password, unauthorized access and roundtrip.
- [ ] Calls: connect chat buttons and incoming accept/reject UI; retain SDP and early ICE, reject unrelated signaling, release media on errors/hangup. Test signaling state machine; manually verify two clients.
- [ ] Attachments: bounded encrypted file messages with picker, metadata and safe export. Test malformed/oversized data and encrypted roundtrip.
- [ ] Platforms: scaffold Windows/macOS, configure permissions, web SQLite assets and API URL; run analyzer, unit/integration tests, available release builds; add CI build matrix for Apple runners.
- [ ] Report actual evidence and remaining device/provider configuration, without describing untested Apple builds as verified.

## Baseline evidence (2026-09-13)

Flutter 3.41.2/Dart 3.11, .NET SDK 10.0.401. Existing Flutter suite: 85 passed. Backend builds; 15 tests passed, 86 integration tests failed because Docker was stopped. Docker startup requested. NuGet reports transitive SSH.NET 2025.1.0 advisory NU1903.

Confirmed source gaps: startup never connects SignalR or redirects onboarding; API localhost:5000 differs from compose :8080; group creation local-only; group cipher throws; call/attachment buttons empty; backup calls account registration and restore unimplemented; account ID placeholder; queue deletes before recipient persistence; local DB not SQLCipher-encrypted despite README wording.

Execution ownership: root startup/network/calls/platform integration; delivery worker server queue/hub; groups worker group/chat/inbox; backup worker account/backup UI and endpoint authorization. Shared interfaces coordinated in task messages. Existing user files .claude/ and FABLE.md preserved.
