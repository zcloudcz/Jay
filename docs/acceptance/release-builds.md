# Release builds and deploy — how to run

Owner: R01. Covers `.github/workflows/ci.yml` (tests + sanity builds, run
automatically) and `.github/workflows/deploy.yml` (manual, SHA-pinned release
to the existing beta). Neither workflow has been run on GitHub's hosted
runners as part of this package — see "Verification status" below.

## CI (`ci.yml`) — automatic

Runs on every push/PR to `main`/`master`/`develop` touching `src/**`,
`infra/**`, or the workflow files themselves.

- `backend`: `dotnet test` against the integration suite.
- `flutter`: `flutter analyze` + `flutter test`.
- `infra-lint`: `az bicep build` on every `infra/**/*.bicep` file. Compiles
  only — never runs `az deployment ... what-if` or touches Azure (that stays
  a manual, read-only step owned by I01).
- `dev-build`: builds all five platforms as a compile sanity check only, with
  a placeholder API URL (`https://ci-sanity-build.invalid`). These artifacts
  are **not** for distribution and are never consumed by `deploy.yml`.

## Deploy (`deploy.yml`) — manual, one commit SHA at a time

Trigger from GitHub Actions → Deploy → "Run workflow". Inputs:

- `commit_sha` — the exact commit to test, build and ship. Must be a full
  SHA, not a branch name, so the tests that gate the deploy and the
  artifacts that get shipped are provably the same bytes.
- `confirm_backup` — checkbox. You must take (or confirm, per the I02
  runbook at `docs/ops/postgres-restore.md`) a database backup immediately
  before checking this box. The workflow fails immediately if unchecked.

Job order: `validate-inputs` → `test` (backend + Flutter, pinned to
`commit_sha`) → `build-api` / `build-clients` (five platforms + the API
package, each with a build manifest and SHA256) → `deploy-api` /
`deploy-web` (existing App Service `calltype-beta-zahy` / Static Web App
`calltype-beta-web` only — the workflow fails if the target App Service does
not exist, it never provisions one) → `smoke-test`.

Concurrency: deploys of this environment queue (`concurrency: deploy-calltype-beta`,
`cancel-in-progress: false`) — the B1 plan has no deployment slots, so
cancelling mid-deploy could leave the app half-updated with no safe target
to fall back to.

### Required repository configuration (names only)

| Kind | Name | Purpose |
| --- | --- | --- |
| Variable | `AZURE_RESOURCE_GROUP` | e.g. `rg-calltype-beta` |
| Variable | `AZURE_WEBAPP_NAME` | e.g. `calltype-beta-zahy` |
| Variable | `CALLTYPE_API_BASE_URL` | Public HTTPS API URL compiled into clients |
| Variable | `CALLTYPE_SWA_URL` | Public web URL, used only by the smoke test |
| Secret | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` | OIDC federated credential for `azure/login` — no client secret stored |
| Secret | `AZURE_SWA_DEPLOYMENT_TOKEN` | Static Web Apps deploy action has no OIDC path; scope this token to the one SWA |
| Secret | `CALLTYPE_DB_CONNECTION_STRING` | Used only by the explicit `dotnet ef database update` step |

`CALLTYPE_API_BASE_URL` is intentionally a variable, not a secret — it is
compiled in plain text into every client binary and is not sensitive.

Remove the old `AZURE_CREDENTIALS`, `ACR_LOGIN_SERVER`, `ACR_USERNAME`,
`ACR_PASSWORD` secrets — the previous Container Apps/ACR deploy path no
longer exists.

### Rejected on purpose

- `commit_sha` that doesn't resolve to a real commit → `validate-inputs` fails.
- `confirm_backup` unchecked → `validate-inputs` fails.
- Empty, `http://`, or loopback (`localhost`/`127.0.0.1`/`::1`) `CALLTYPE_API_BASE_URL`
  → `build-clients` fails before any client is built.
- Missing target App Service → `deploy-api` fails at `az webapp show`, before
  any deploy is attempted.

### Firebase / push configuration (K04)

`google-services.json` (Android) and `GoogleService-Info.plist`
(iOS/macOS) are **not present in this repository** — D03 has not yet handed
off a Firebase project, and none is created here. Until they exist:

- Android: `POST_NOTIFICATIONS` permission is declared
  (`android/app/src/main/AndroidManifest.xml`) so notifications can be shown
  once a Firebase config file is added; push itself will not work without it.
- iOS: `UIBackgroundModes: remote-notification` is declared
  (`ios/Runner/Info.plist`) so the app can receive background pushes. Full
  Push Notifications capability additionally needs an `aps-environment`
  entitlement wired into Xcode code signing, which needs an Apple developer
  team — **BLOCKED**, no Apple team available in this environment.
- macOS: same signing dependency as iOS — **BLOCKED**.
- Web: needs a `firebase-messaging-sw.js` service worker containing the
  Firebase web config (apiKey, VAPID key, etc.) that D03 has not yet
  supplied — **BLOCKED**, not fabricated here.
- The server-side Firebase service-account JSON (`Push__FcmServiceAccountJson`)
  is an App Service setting, never a client artifact; nothing in this
  package writes it into any built package.

## Verification status

| Check | Status | Notes |
| --- | --- | --- |
| `ci.yml` / `deploy.yml` YAML parses | PASS | `python -c "import yaml; yaml.safe_load(...)"` on both files, exit 0, run 2026-09-16 |
| Hosted CI run | NOT_RUN | Hosted GitHub Actions runs are blocked in this environment; nothing here claims a green hosted run |
| Hosted deploy run | NOT_RUN | Same — no Azure credentials or hosted runner available here |
| `az bicep build` locally | NOT_RUN | No `infra/*.bicep` template from I01 exists yet in this worktree at time of writing; the CI job will exercise it once one lands |
| Firebase/push wiring | BLOCKED | No Firebase project handed off by D03 yet (see above) |
| Apple signing / entitlements | BLOCKED | No Apple developer team available |

Nothing above should be read as "PASS" until it has actually run against a
real commit on hosted infrastructure.
