# Jay

**Jay** is an anonymous-first, end-to-end encrypted messenger for people and bots. No phone number, no e-mail: a device registers on its own and gets a public handle like `CT-XXXX-XXXX`. The server relays ciphertext it cannot read.

- Web: <https://jay.zcloud.cz>
- Clients: Android, iOS, web, Windows, macOS (Flutter)
- Status: running in production as a free service. Expect rough edges.

> `CallType` is the internal code name. Namespaces, packages, bundle IDs, `CT-` handles and the protocol's domain-separation strings keep it on purpose, because renaming them would break existing identities.

## What it does

- 1:1 and group chat, replies, reactions, polls, pins, attachments, voice messages
- Voice and video calls (WebRTC, TURN)
- Multi-device and optional encrypted backup (an account is only needed for these)
- Channels: public one-way feeds (**not** end-to-end encrypted, by design)
- Bots as ordinary E2E devices, not a server-side Bot API: commands, buttons, mentions, bot-to-bot conversations in groups with limits
- Bridges: [Hermes Agent](src/bots/hermes_bridge), any [A2A](https://a2a-protocol.org) agent ([a2a_bridge](src/bots/a2a_bridge))
- Optional Business mode for organizations: roles, MFA and a **visible** auditor member. There is never a hidden one.

## Security model, honestly

- Messages use a **custom Dart implementation** of X3DH + Double Ratchet (X25519, Ed25519, HKDF-SHA256, AES-256-GCM). It is **not libsignal and has not been independently audited.** See [docs/security/crypto-baseline.md](docs/security/crypto-baseline.md).
- The server stores ciphertext until delivery. Group names are encrypted and push notifications are generic, so Apple and Google see no sender or group name.
- The server **does see metadata**: which device sends to which device or group and when, IP addresses, device display names and push tokens.
- Identity keys are pinned on first use. Compare safety numbers to rule out a man in the middle.
- The local message database is not SQLCipher-encrypted. It relies on OS and browser storage protection.
- **Bots see plaintext.** Whoever runs a bot, and any LLM behind it, reads what you send to it.

Found a vulnerability? Report it privately to martin@zcloud.cz (also in the API's `/.well-known/security.txt`) instead of opening a public issue. Process: [docs/security/incident-response.md](docs/security/incident-response.md).

## Repository layout

| Path | What |
| --- | --- |
| `src/server/CallType.Api` | ASP.NET Core 10 API: Minimal API endpoints, SignalR hub, EF Core / PostgreSQL |
| `src/server/CallType.Audit` | Business mode: organizations, audit archive, emergency channel |
| `src/client/calltype_core` | Pure Dart core shared by the app and bots: crypto, wire payloads, API client, storage |
| `src/client/calltype` | Flutter app |
| `src/client/jay_admin` | Operator web (channel moderation) |
| `src/bots/calltype_bot` | Headless bot runtime (pure Dart) |
| `src/bots/hermes_bridge`, `src/bots/a2a_bridge`, `src/bots/jay_archiver` | Bridges and the Business archiver built on the bot runtime |
| `docs/` | Specs, security docs, ops runbooks |
| `infra/` | Azure Bicep (`beta-appservice.bicep` is the current one) |

## Run locally

Requirements: Docker, .NET 10, Flutter 3.41.x.

```sh
docker compose up --build -d          # API on http://localhost:8080 + PostgreSQL + Azurite
cd src/client/calltype
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run -d chrome --web-port=8090 --dart-define=API_BASE_URL=http://localhost:8080
```

- The secrets in `docker-compose.yml` are local development values only.
- On a phone, `localhost` is the phone. Pass an API URL the device can reach via `--dart-define=API_BASE_URL=...`.
- Web builds need `web/sqlite3.wasm` and `web/drift_worker.js` in the published output.

## Server configuration

| Setting | Purpose |
| --- | --- |
| `ConnectionStrings__DefaultConnection` | PostgreSQL |
| `ConnectionStrings__BlobStorage` | Azure Blob storage or Azurite (backups, media) |
| `Jwt__Secret` | JWT signing secret, at least 32 characters |
| `Cors__AllowedOrigins__0` | Browser client origin |
| `Turn__Provider` | `cloudflare` or `shared-secret` (self-hosted coturn) |
| `Push__*` | FCM / APNs / Web Push, see [CLAUDE.md](CLAUDE.md) |
| `ConnectionStrings__Audit` | Enables Business mode |

## Tests

```sh
dotnet test src/server/CallType.Api.Tests      # needs Docker (Testcontainers)
cd src/client/calltype && flutter analyze && flutter test
```

## Contributing

Issues and pull requests are welcome. By contributing you agree that your contribution is licensed under the AGPL-3.0 and that ZCloud may also distribute it in the official app-store builds.

## License

[GNU Affero General Public License v3.0](LICENSE). If you run a modified Jay server for others, you must offer them its source code.

Copyright © 2026 ZCloud (zcloud.cz)
