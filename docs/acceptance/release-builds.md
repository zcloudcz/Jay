# Release builds and deploy — how to run

Owner: stream P (originally R01). Covers `.github/workflows/ci.yml` (tests +
sanity builds, run automatically), `.github/workflows/deploy.yml` (manual,
SHA-pinned API + web release to the existing beta) and
`.github/workflows/release-native.yml` (manual, SHA-pinned signed store /
download builds). None of them has been run on GitHub's hosted runners as part
of the 2026-09-29 rework — see "Verification status" below.

GitHub Actions only start while the repository is public (billing, R-O2). Every
run below happens in an owner-approved **public window**:

1. owner's OK for this window and this run,
2. repository → public,
3. `gh workflow run deploy.yml …` and/or `gh workflow run release-native.yml …`,
4. approve the environments the run waits for (`calltype-beta`, `android-release`, `apple-testflight`, …),
5. when the runs are done, repository → private,
6. record the run id and result in `docs/acceptance/`.

During the window logs and artifacts are public. Signed AAB/IPA/MSIX/dmg are
distributable binaries, that is acceptable; keystores, `.p8`, `.p12` and
service-account files are never uploaded and never printed.

## Versioning (P2)

One version for every platform of a commit, computed by
`.github/scripts/version.sh <sha> [offset]`:

- `build_name` = `major.minor.patch` from `src/client/calltype/pubspec.yaml`
  `version:` at that SHA. **Bump it by hand in a commit before a release.**
  The `+N` part is ignored by CI.
- `build_number` = `git rev-list --count <sha>` (+ `build_number_offset`).
  Deterministic per SHA, monotonic along `master`, so the web (deploy.yml) and
  the store builds (release-native.yml) of one SHA show the same number.
  Requires a full clone (`fetch-depth: 0`; locally `git fetch --unshallow`) and
  a SHA on `master` for store releases (deploy.yml allows a branch SHA with a
  warning). `master` must be protected against force pushes, which would lower
  the numbers.
- Limits: every part ≤ 65 535 (Windows FILEVERSION / MSIX); `msix_version` =
  `major.minor.build_number.0`.
- Every client build gets `--build-name`, `--build-number`,
  `--dart-define=JAY_DISTRIBUTION=<web|play|testflight|direct|msstore>` and
  `--dart-define=JAY_COMMIT_SHA=<sha>`. Settings → About shows
  `Jay <build_name> (<build_number>) beta` (`AppVersionLabel`), with the short
  SHA as a tooltip. The web reads it from `version.json`.
- Every artifact carries `build-manifest.json` (`.github/scripts/build-manifest.sh`):
  `commitSha`, `platform`, `distribution`, `buildName`, `buildNumber`,
  `apiBaseUrl`, `flutterVersion`, `artifactSha256`, and for native builds
  `signed` (+ `signingCertSha256` on Android).

## CI (`ci.yml`) — automatic

Runs on every push/PR to `main`/`master`/`develop` touching `src/**`,
`infra/**`, `.github/workflows/**` or `.github/scripts/**`.

- `backend`: `dotnet test` against the integration suite.
- `flutter`: core + bots + app analyze and tests, OSV-Scanner.
- `platform-config`: `check-app-ids.sh` (one identifier `cz.zcloud.jay` on
  every platform, entitlements wired, no committed Apple team) and its
  negative test, `test-version.sh`, `test-firebase-config.sh`, shellcheck, and
  `actionlint` from a version- and sha256-pinned release binary.
- `infra-lint`: `az bicep build` on every `infra/**/*.bicep` file.
- `dev-build`: builds all five platforms as a compile sanity check only, with
  a placeholder API URL (`https://ci-sanity-build.invalid`); Android builds the
  APK and the AAB (debug-signed). Not for distribution.
- `android-signing-smoke`: generates a throw-away keystore, proves that a
  release build with `JAY_REQUIRE_RELEASE_SIGNING=true` fails without a key and
  is signed with exactly that key when given one. No real secret involved.

`ci.yml` reads no signing secret and runs on `pull_request`; the release
workflows never do.

## Deploy (`deploy.yml`) — API + web, manual, one commit SHA at a time

```bash
gh workflow run deploy.yml -R zcloudcz/Jay -f commit_sha=<full sha> -f confirm_backup=true
```

- `commit_sha` — the exact commit to test, build and ship (full SHA, never a
  branch name).
- `confirm_backup` — take (or confirm, per `docs/ops/postgres-restore.md`) a
  database backup immediately before checking it. Unchecked → fails.

Job order: `validate-inputs` → `test` (backend) ∥ `client-tests`
(reusable `_client-tests.yml`) ∥ `version` → `sbom-dart` / `build-api` /
`build-web` (web build with version, `JAY_DISTRIBUTION=web`, Firebase web
config, manifest) → `deploy-api` / `deploy-web` (existing App Service /
Static Web App only, never provisions) → `smoke-test`.

Native clients are **not** built here any more (they need signing
environments, and macOS minutes should not be spent on every web deploy);
use `release-native.yml`.

Concurrency: `deploy-calltype-beta`, `cancel-in-progress: false` — the B1 plan
has no deployment slots.

## Release native (`release-native.yml`) — stores and downloads, manual

```bash
gh workflow run release-native.yml -R zcloudcz/Jay -f commit_sha=<full sha on master> \
  -f android=build|internal -f ios=build|testflight   # others default to skip
```

| Input | Values | Status |
| --- | --- | --- |
| `android` | `skip` · `build` (signed AAB artifact) · `internal` (+ Play internal testing) | P4, `docs/acceptance/android-play.md` |
| `ios` | `skip` · `build` (signed IPA artifact) · `testflight` (+ App Store Connect) | P5, `docs/acceptance/ios-testflight.md` |
| `macos` | bool | stub, fails — P6 (wave 2) |
| `windows` | `skip` · `direct` · `store` | stub, fails — P7 (wave 2) |
| `linux` | bool | stub, fails — P8 (wave 2) |
| `publish_downloads` | bool | stub, fails — P10 (wave 2) |
| `build_number_offset` | number, default 0 | only for a forced re-upload of the same SHA |

Jobs: `version` → `client-tests` → one reusable `_release-<platform>.yml` per
requested platform, each in its own environment. Concurrency `release-native`,
never cancelled (two uploads with one build number would collide).

**Without signing secrets a platform degrades to an unsigned build**
(artifact suffix `-unsigned`, manifest `"signed": false`), so the public window
and forks can still prove the build. A store upload (`android=internal`,
`ios=testflight`) without secrets fails.

Security rules for every release workflow: only `workflow_dispatch` /
`workflow_call`; `permissions: contents: read` (+ `id-token: write` only on
OIDC jobs); no `pull_request_target`; environments with the owner as required
reviewer and deployment branch `master`; `persist-credentials: false`;
third-party actions pinned to a full SHA; keys decoded into `$RUNNER_TEMP` and
removed by a `trap`; no `set -x`.

## Required repository configuration (names only)

Full owner checklist in order: `docs/superpowers/plans/2026-09-29-gap-platform.md` §9.

| Where | Kind | Name | Used by | Purpose |
| --- | --- | --- | --- | --- |
| repo | Variable | `AZURE_RESOURCE_GROUP` | deploy | e.g. `rg-calltype-beta` |
| repo | Variable | `AZURE_WEBAPP_NAME` | deploy | e.g. `calltype-beta-zahy` |
| repo | Variable | `CALLTYPE_API_BASE_URL` | deploy, release-native | Public HTTPS API URL compiled into clients (not secret) |
| repo | Variable | `CALLTYPE_SWA_URL` | deploy | smoke test only |
| `calltype-beta` | Secret | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` | deploy | OIDC for `azure/login`, no client secret |
| `calltype-beta` | Secret | `AZURE_SWA_DEPLOYMENT_TOKEN` | deploy | SWA deploy has no OIDC path |
| repo | Secret | `FIREBASE_CLIENT_CONFIG_JSON_B64` | deploy (web), release-native | Firebase client options, see below |
| repo | Secret | `FIREBASE_ANDROID_GOOGLE_SERVICES_JSON_B64` | release-native android | `google-services.json` |
| repo | Secret | `FIREBASE_APPLE_GOOGLE_SERVICE_INFO_PLIST_B64` | release-native ios | optional, only if N needs it (R-P12) |
| `android-release` | Secret | `ANDROID_UPLOAD_KEYSTORE_B64`, `ANDROID_UPLOAD_KEYSTORE_PASSWORD`, `ANDROID_UPLOAD_KEY_ALIAS`, `ANDROID_UPLOAD_KEY_PASSWORD` | android | upload key |
| `android-release` | Variable | `ANDROID_UPLOAD_CERT_SHA256` | android | expected upload certificate (hex, colons optional) |
| `android-release` | Secret | `PLAY_SERVICE_ACCOUNT_JSON` | android `internal` | plain JSON of the Play service account |
| `apple-testflight` | Secret | `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8_BASE64` | ios | App Store Connect API key (cloud signing) |
| `apple-testflight` | Variable | `APPLE_TEAM_ID` | ios | 10-char team id, passed to xcodebuild, never committed |

Remove the old `AZURE_CREDENTIALS`, `ACR_LOGIN_SERVER`, `ACR_USERNAME`,
`ACR_PASSWORD` secrets if still present.

## Firebase / push configuration (K04, P3)

Nothing Firebase is committed. The values are public identifiers, but keeping
them out of git stops forks and dev builds from talking to our project.

- The app reads its `FirebaseOptions` from dart-defines
  (`lib/core/config/firebase_config.dart`, contract X0-P6). Missing or
  incomplete values for the running platform = `null` =
  `PushStatus.notConfigured`; dev and CI sanity builds behave as before.
- Release jobs run `.github/scripts/firebase-config.sh <platform>`, which
  writes git-ignored files from the secrets:
  - always `src/client/calltype/build-defines/firebase.json`
    (`{}` plus a `::warning::` without config), passed as
    `--dart-define-from-file=build-defines/firebase.json`. Only `FIREBASE_*`
    keys pass, so the secret cannot override `API_BASE_URL` or
    `JAY_DISTRIBUTION`. Windows/Linux always get `{}`.
  - web: overwrites `web/firebase-config.js` (committed default:
    `self.JAY_FIREBASE_CONFIG = null;`) with the six Firebase JS SDK keys, only
    when the web keys are complete. The push service worker (stream N) loads it.
  - android: `android/app/google-services.json`; the Gradle build then applies
    `com.google.gms.google-services` (only when the file exists). The script
    refuses a file without an Android client for `cz.zcloud.jay` or from a
    different Firebase project than the client config.
  - ios/macos: `GoogleService-Info.plist`, only if that optional secret is set;
    `BUNDLE_ID` must be `cz.zcloud.jay`.
- The script never prints a decoded value and never runs with `set -x`.
- Secret formats:
  - `FIREBASE_CLIENT_CONFIG_JSON_B64` = base64 of a **flat** JSON object of
    strings with the frozen keys: `FIREBASE_PROJECT_ID`,
    `FIREBASE_MESSAGING_SENDER_ID`, `FIREBASE_STORAGE_BUCKET`,
    `FIREBASE_WEB_API_KEY`, `FIREBASE_WEB_APP_ID`, `FIREBASE_WEB_AUTH_DOMAIN`,
    `FIREBASE_WEB_VAPID_KEY`, `FIREBASE_ANDROID_API_KEY`,
    `FIREBASE_ANDROID_APP_ID`, `FIREBASE_APPLE_API_KEY`, `FIREBASE_IOS_APP_ID`,
    `FIREBASE_MACOS_APP_ID` (may equal the iOS app id),
    `FIREBASE_APPLE_BUNDLE_ID` (= `cz.zcloud.jay`). Values come from Firebase
    console → Project settings → Your apps.
  - `FIREBASE_ANDROID_GOOGLE_SERVICES_JSON_B64` = base64 of the downloaded
    `google-services.json`.
  - Line breaks in the base64 are tolerated.
- The server-side service account (`Push__FcmServiceAccountJson`) is an App
  Service setting, never a client artifact and never a GitHub secret.

## Rejected on purpose

- `commit_sha` that is not a full 40-char SHA of an existing commit → `version` / `validate-inputs` fail.
- Store release of a SHA that is not on `master`, or from a shallow clone → `version` fails.
- `confirm_backup` unchecked → `validate-inputs` fails (deploy).
- Empty, `http://` or loopback `CALLTYPE_API_BASE_URL` → the build job fails before building (`check-api-url.sh`).
- Android release with the upload key whose certificate differs from `ANDROID_UPLOAD_CERT_SHA256` → fails before any upload.
- iOS archive without `aps-environment` or `associated-domains` → fails before export.
- Store upload requested without its secrets → fails.
- Firebase secret for another app/project → `firebase-config.sh` fails.
- Missing target App Service → `deploy-api` fails at `az webapp show`.

## Verification status

| Check | Status | Notes |
| --- | --- | --- |
| `actionlint` 1.7.9 (+ shellcheck 0.11.0) over all workflows | PASS | local, 2026-09-29; binary sha256-verified from the GitHub release |
| YAML parse of all workflows | PASS | `python -c "import yaml; yaml.safe_load(...)"`, 2026-09-29 |
| shellcheck `.github/scripts/*.sh` | PASS | local, 2026-09-29 |
| `test-version.sh` | PASS (17) | local, 2026-09-29 |
| `test-firebase-config.sh` | PASS (18) | local, 2026-09-29 |
| `check-app-ids.sh` + `test-check-app-ids.sh` | PASS (7) | local, 2026-09-29 |
| `AppVersionLabel` widget tests | PASS | `flutter test`, 2026-09-29 |
| Local `flutter build web --release` with version flags + `--dart-define-from-file` (`{}` from `firebase-config.sh web` without secrets) | PASS | 2026-09-29, Flutter 3.41.9: `build/web/version.json` = `1.0.0` / `158`, `JAY_COMMIT_SHA` present in `main.dart.js`, `git status` clean afterwards |
| `flutter build appbundle`, Gradle signing / R8 | NOT_RUN | no Android SDK in this environment; `ci.yml` `dev-build` + `android-signing-smoke` |
| Hosted CI run | NOT_RUN | public window only |
| Hosted deploy run | NOT_RUN | public window + owner OK |
| Hosted release-native run | NOT_RUN | first run: `android=build` (cheapest), then `ios=build` |
| Firebase/push wiring on devices | NOT_RUN | needs the Firebase project (V3) and stream N |

Nothing above should be read as "PASS" for a hosted run until it has actually
run against a real commit on hosted infrastructure.
