# Notifications: client setup and the steps left for Firebase / Apple

Spec: `docs/superpowers/specs/2026-11-06-notifications.md` (section 2 = app).
Code: `src/client/calltype/lib/features/notifications/` and
`lib/core/network/push_service.dart`. Every platform piece sits behind a seam
(`LocalNotifier`, `PushProvider`) with a fake in the tests.

## What the app does

- **Local notifications** on Android, iOS, macOS, Windows, Linux
  (`flutter_local_notifications`) and the web (browser Notification API via
  `package:web`), whenever the app runs: messages, incoming calls, channel
  posts. Skipped for the open chat while the app is focused, for muted chats
  (same per-device mute modes as the server) and for copies from the user's
  own other devices. One notification per conversation (replaced, not
  stacked). Android channels `messages`, `calls`, `channels` (ids match the
  server's FCM payload).
- **Settings > Notifications:** on/off (on registers the push token, off
  sends `DELETE /devices/{id}/push-token`), message preview (default on; off =
  "New message" only), test notification, status line (active / only while
  running / not configured / permission denied / permission needed).
- **Permission:** mobile asks once, on the first hub connect after
  onboarding. The web asks only from a click (Settings button or a one-time
  banner on the chat list), never on page load.
- **Tap** on a local or a server notification opens the conversation
  (`/chats/<id>`) or the channel feed (`/channels/feed/<id>`).
- **Registration** (`PUT /devices/{id}/push-token` with `locale` = app
  language) runs on every hub (re)connect, so a failed attempt is retried.

## Android (FCM)

Works only when `src/client/calltype/android/app/google-services.json` exists
at build time: `app/build.gradle.kts` applies the Google services plugin only
then (the file is git-ignored). Without it the APK still builds, Firebase init
fails at runtime and Settings says push is "not configured"; local
notifications keep working.

CI (`ci.yml` dev build, `deploy.yml` release build) writes the file from the
OPTIONAL repository secret `GOOGLE_SERVICES_JSON_BASE64` before the Android
build, only when the secret is set, and never prints it.

Steps left for "Firebase at the end":

1. Create the Firebase project (company Google account).
2. Add an Android app with package name `cz.zcloud.jay`, download
   `google-services.json`.
3. `base64 -w0 google-services.json` -> GitHub repository secret
   `GOOGLE_SERVICES_JSON_BASE64`.
4. Project settings > Service accounts > Generate new private key -> put the
   whole JSON into the App Service setting `Push__FcmServiceAccountJson`.
5. Build + deploy; Settings > Notifications on an Android device should then
   read "Active, also while Jay is closed".

## iOS (APNs, no Firebase)

- The token comes from UIKit through the method channel
  `cz.zcloud.jay/apns` (`ios/Runner/AppDelegate.swift`), `platform: apns`,
  lowercase hex.
- `ios/Runner/Runner.entitlements` (`aps-environment = production`) is used by
  Release and Profile; `RunnerDebug.entitlements` (`development`) by Debug,
  because a debug build on a device is signed with a development profile.
  Debug tokens are sandbox tokens (server needs `Push:Apns:UseSandbox=true`).
  The simulator gets no token: Settings says "not configured".
- Apple Developer: enable Push Notifications on the App ID `cz.zcloud.jay`,
  then REGENERATE the "Jay App Store" profile and update the secret
  `IOS_PROVISION_PROFILE_BASE64`. `ios-testflight.yml` now refuses a profile
  without `aps-environment = production` before building.
- Server: APNs key (`.p8`) settings `Push:Apns:*` (server part of the spec).

## Web (Web Push)

- `web/push-sw.js`, registered by the app with scope `/push/`: Flutter's own
  `flutter_service_worker.js` owns `/` and a scope holds one worker. The push
  worker has no fetch handler, so it never touches the app or `/admin/`.
  `web/staticwebapp.config.json` needs no change (`/*.js` is already outside
  the navigation fallback).
- The subscription uses the key from `GET /push/webpush-key` (404 = not
  configured on the server) and is sent as `platform: webpush`.
- JS unit test: `node --test test/web/push_sw.test.mjs` (also run from
  `flutter test` when `node` is installed).

## Desktop

Local notifications only (no OS push channel without a store app, spec N7).

## Not verified on Linux (needs a Mac / devices)

iOS / macOS / Windows builds, real APNs / FCM / Web Push delivery, the
notification tap paths on real devices. See the acceptance checklist in the
feature report.
