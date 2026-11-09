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

## Call ringing on a closed app (CallKit, PushKit, Android full screen)

Spec: `docs/superpowers/specs/2026-11-06-call-ringing.md` (section 2 = app).
Package: `flutter_callkit_incoming` **3.1.6** (pinned in `pubspec.yaml`; it
raised the iOS minimum to 15.0, so `ios/Podfile` and the Xcode project are on
15.0 now). Code: `lib/features/calls/call_ring.dart` (the `CallRingPlatform`
seam, `ringIdFor`), `call_ring_coordinator.dart` (all business logic, unit
tested with a fake platform), `callkit_ring_platform.dart` (the plugin, the
Android FCM background handler), `ios/Runner/AppDelegate.swift` (PushKit).

What happens:

- **Registration.** Android sends `ringCalls: true` with its FCM token. iOS
  registers PushKit at launch; the VoIP token goes to
  `PUT /devices/{id}/voip-token` on every hub (re)connect and whenever it
  changes; an invalidated token and notifications off send
  `DELETE /devices/{id}/voip-token` (next to `DELETE .../push-token`).
- **iOS ring.** `AppDelegate.pushRegistry(...didReceiveIncomingPushWith...)`
  reports the call to CallKit synchronously via the plugin: caller "Jay",
  generic handle, audio only, not in Recents, 45 s, CallKit UUID = `callId`
  (UUIDv5 of it when it is not a UUID, same function in Dart). If the plugin
  is not registered yet (no Flutter engine), the push is reported on a
  fallback `CXProvider` and ended at once, so iOS does not kill the app; the
  caller's hangup later shows as a missed call. WebRTC uses the audio session
  CallKit activates (`RTCAudioSession.useManualAudio` only for CallKit calls).
- **Android ring.** The FCM background handler (`ringPushBackgroundHandler`)
  shows the plugin's full-screen call ("Jay" + localized "Incoming call",
  channel named like the app's "Calls" channel); `call_cancelled` ends it and
  leaves a localized missed-call notification. Android 14+ without the
  full-screen permission falls back to a heads-up notification; Settings >
  Notifications then shows a row that opens the system setting.
- **Dart flow** (`CallRingCoordinator`): accept -> connect the hub,
  `RequestPendingCalls()`, wait up to 10 s for the offer, answer it without the
  in-app ringing screen, the call screen opens; no offer -> end + missed call.
  Decline -> `DeclinePendingCall(callId)` (or a `declined` hangup if the offer
  is already here). `cancelled` -> end + missed call. In-app hangup / failure
  ends the system call; connected starts its timer; system mute or hold mutes
  the microphone. The caller shows "Ringing..." on the `ringing` signal and
  "Call declined." on a `declined` hangup. Offers while the app is in the
  foreground keep the in-app ringing UI.

Known limits (by design or to verify on devices):

- iOS keychain items are `unlocked`-only (flutter_secure_storage default), so
  a call answered on a LOCKED iPhone connects once the phone is unlocked.
- Whether iOS starts the Flutter engine for a VoIP push of a killed app under
  the UIScene lifecycle is not documented; if it does not, the fallback
  above applies (no crash, no ring). Check item 2 below.
- Android: `MainActivity` stays `singleTop` (the package README suggests
  `singleInstance`, which would change deep links and pickers); accepting on
  the lock screen opens the app after the user unlocks.

### Manual acceptance (TestFlight + Android build)

Server with the `feat/call-ringing-server` part deployed; two devices; the
callee's app swiped away (killed) unless stated otherwise.

1. iPhone, app in background, phone locked: call it. CallKit rings showing
   "Jay"; the caller shows "Ringing...".
2. Same with the app killed (swiped away) and after a reboot + one unlock.
   It must ring; if it never rings but the app does not crash, the engine was
   not up (fallback path): report it, the fix is a pre-warmed engine.
3. Answer on the iPhone: unlock if asked, the call screen opens connected,
   audio both ways, speaker / mute from the CallKit screen work, ending from
   CallKit ends it on both sides.
4. Decline on the lock screen: the caller sees "Call declined." at once.
5. Caller hangs up while the iPhone rings: the ringing stops (when the app
   was woken) and a "Missed call" notification appears (at the latest on the
   next app start within 2 minutes).
6. Nobody answers for 45 s: both sides stop, the callee gets "Missed call".
7. Android 13 and 14+, app killed, screen locked: full-screen incoming call
   with "Jay" / "Incoming call" in the phone language; Accept opens the app
   into the connected call (after unlock); Decline -> caller "Call
   declined."; caller hangup -> ringing stops + "Missed call".
8. Android 14+: revoke "Full screen notifications" for Jay in the system
   settings: the call rings as a heads-up notification and Settings >
   Notifications shows the "Full-screen incoming calls" row; tapping it opens
   the system page, allowing hides the row.
9. Regression: calls with both apps open still ring in-app on both platforms
   (no CallKit), and outgoing calls from iOS have audio.
10. Notifications off in Settings: no ring push arrives any more (server
    forgot both tokens).

## Not verified on Linux (needs a Mac / devices)

iOS / macOS / Windows builds, real APNs / FCM / Web Push delivery, the
notification tap paths on real devices. See the acceptance checklist in the
feature report.
