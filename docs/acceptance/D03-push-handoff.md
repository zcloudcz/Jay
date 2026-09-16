# D03 — push notification handoff for R01 / B00

## Public client config (safe to commit, goes into the client artifact)

- **Android**: `google-services.json` (Firebase console → Project settings →
  your Android app). Placed at `src/client/calltype/android/app/`.
- **iOS**: `GoogleService-Info.plist` (Firebase console → your iOS app).
  Placed at `src/client/calltype/ios/Runner/`. Also requires the
  **Push Notifications** and **Background Modes → Remote notifications**
  capabilities enabled in the Xcode project / entitlements — R01 owns
  Apple signing, so this must be wired into the signed build, not the
  unsigned one.
- **macOS**: same `GoogleService-Info.plist` mechanism as iOS, plus the
  same two capabilities in the macOS target's entitlements.
- **Web**: Firebase web config object (apiKey/authDomain/projectId/...,
  all public identifiers, not secrets) plus a VAPID public key
  (Firebase console → Cloud Messaging → Web configuration → Web Push
  certificates). The web app also needs a service worker
  (`firebase-messaging-sw.js`) registered at the web root so background
  push works in a browser tab that isn't focused — this file is currently
  **missing** from `src/client/calltype/web/` and must be added when R01
  wires up the web build.
- **Windows**: intentionally out of scope — Firebase Messaging has no
  Windows Flutter plugin. No push on this platform; the K04 contract
  requires this to be reported as UNSUPPORTED, not silently absent.

## Server secret (never in the client artifact)

- `Push:FcmServiceAccountJson` (env `Push__FcmServiceAccountJson`) — the
  **entire** service account JSON downloaded from Firebase console →
  Project settings → Service accounts → Generate new private key. This is
  a server-only secret (private key + client_email) and must go through
  the same secret pipeline as `Jwt__Secret`, never into a build artifact
  or repo file.

## Known gap — visible notification while backgrounded/terminated

The server sends a **data-only** FCM message (`data: { type: "new_message" }`,
no `notification` block) by design: the E2E-encrypted architecture means the
server has no plaintext to put in a title/body, and a data-only payload is
guaranteed to reach the client's own handler rather than the OS tray.

Consequence per K04 ("data-only handler alone is not proof of a visible
notification"): on Android/iOS, a data-only message delivered while the app
is backgrounded or terminated does **not** by itself produce a visible system
notification — that requires either:
1. Adding a local-notifications plugin (e.g. `flutter_local_notifications`)
   and calling it from a background message handler, which needs a
   `pubspec.yaml` dependency change (B00) and a top-level background handler
   registered in `main.dart` (B00), or
2. Switching the FCM payload to include a generic `notification` block
   (e.g. title "CallType", body "New message") so the OS auto-displays it —
   this is a payload/architecture decision, flagged here rather than made
   unilaterally since it changes the "no notification block" design note in
   the project `CLAUDE.md`.

D03 did not pick either option unilaterally; `PushService` is wired so
whichever is chosen only needs to plug into `onMessageReceived` /
`onNotificationOpened` (see below). Q01 must record background/terminated
visibility as BLOCKED or UNSUPPORTED per platform until one of the two is
implemented and verified on a physical device — do not mark it PASS off the
data-only handler alone.

## Public `PushService` API change (small, backwards compatible)

`PushService(this._api, this._deviceId, {PushMessagingClient? messaging,
this.onMessageReceived, this.onNotificationOpened})` — existing call sites
(`PushService(apiClient, deviceId)` in `lib/main.dart`) keep working
unchanged since all new parameters are optional. `messaging` is a test seam
only; production code should not pass it.

New optional callbacks for whoever wires navigation in `lib/app/`:
- `onMessageReceived` — foreground push arrived; hook to refresh the inbox.
- `onNotificationOpened` — user tapped a background/terminated notification;
  hook to navigate to the conversation list and let the existing
  reconnect/replay path fetch the message. Per K04, no new endpoint reads
  plaintext from this callback.

Also new: `PushService.status` (`PushStatus`: `unsupported` / `notConfigured`
/ `permissionDenied` / `registered`) so the UI can distinguish "user said no"
from "this build has no Firebase config" from "it's working", as required by
K04.
