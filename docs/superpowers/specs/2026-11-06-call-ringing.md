# Call ringing on a closed app (CallKit + VoIP push, Android full-screen) - design + contract

Status: approved by Martin 2026-11-06 ("rovnou to implementuj"). Prepared by Hermes Dev.
Base: `master` at 08e88c0 (notifications release). Branches: `feat/call-ringing-server`, `feat/call-ringing-app`,
merged into `feat/call-ringing`. Every layer codes against this file. Lifts N7's "CallKit/VoIP push and full-screen
ringing" out of scope of `2026-11-06-notifications.md`.

## Why

Today an `offer` to an offline device gets an immediate `unavailable` reply (the caller's UI ends the call) plus a
generic "Incoming call" alert push. The callee's phone does not ring; by the time they open the app the call is gone.
A messenger whose calls never ring on a locked phone is not usable for calls.

## Decisions

| # | Decision | Why |
|---|---|---|
| R1 | The server keeps a **pending call** for an offline callee that can ring (R2): the offer envelope plus the caller's later `ice-candidate` signals, in memory (`IMemoryCache`, single B1 instance), for **45 s** (the caller's ring timeout). On the callee's next hub connect they are delivered as ordinary `CallSignal`s, in order. | Ringing needs the offer to survive until the callee's app is up |
| R2 | "Can ring" = iOS device with a **VoIP token** (PushKit), or Android device whose FCM registration declared `ringCalls: true`. Anything else (web, desktop, old app versions) keeps today's behaviour exactly: `unavailable` + alert push. | Old clients must not regress; capability is explicit, never guessed |
| R3 | iOS: VoIP push (`apns-push-type: voip`, topic `<BundleId>.voip`, priority 10, expiration 0) with the same `.p8` token auth. The app MUST report it to CallKit immediately (iOS kills apps that do not). Android: data-only high-priority FCM message, `ttl` 45 s; the app's background handler shows a full-screen call notification. | Platform rules; no new Apple asset needed (token auth covers the voip topic) |
| R4 | Push payload stays metadata-free like N2: `type`, `callId` (random UUID the caller generated), `conversationId` (same value as today's call push), `v`. **No caller name or device id.** CallKit / Android first show "Jay" + localized "Incoming call"; once the offer arrives over SignalR the app may update the displayed name from its local contacts. | E2E/metadata stance of N2 |
| R5 | The caller is told the callee is being rung: `CallSignal { signalType: "ringing" }` instead of `unavailable`. The caller keeps ringing until answer, hangup or its existing 45 s timeout. An old caller app ignores the unknown signal and simply rings to its timeout. | Caller UX; backward compatible |
| R6 | Cancel: caller `hangup` (or 45 s expiry) of a pending call removes it and leaves a **tombstone** for 2 min. A callee connecting with a tombstone gets `CallSignal { signalType: "cancelled" }` for that call; the app ends the CallKit call / dismisses the notification and shows a local "Missed call" notification. Android additionally gets a data-only FCM `call_cancelled` right away. iOS gets nothing extra (a VoIP push would have to report a NEW call). | iOS VoIP rule; Android can dismiss immediately |
| R7 | Decline on the lock screen: the app calls hub `DeclinePendingCall(callId)`; the server removes the pending call and relays `CallSignal { signalType: "hangup", payload: <envelope with callId, payload "declined"> }` to the caller (if online). | Caller learns at once, no need to wait for the offer |
| R8 | Mutes unchanged: a 1:1 mute in mode `all` means no push and no pending call (caller gets `unavailable`, as today). | N5 |
| R9 | Out of scope: video preview in CallKit, call history integration in the iOS Phone app ("Recents" is CallKit default, leave `includesCallsInRecents` = false for privacy), group calls, desktop. | Size |

## 1. Server contract (`feat/call-ringing-server`)

### 1.1 Registration
- Migration `AddVoipPushToken` (`--context AppDbContext`, additive): `Device.VoipPushToken` (string?, max 200),
  `Device.PushRingCalls` (bool, default false).
- `PUT /devices/{id}/voip-token` (self only, else 403; rate limit `api`) body `{"token": "<hex 64..200>"}` -> 204;
  invalid -> 400 `invalid_token` (same hex rule as `apns`, stored lowercase). `DELETE /devices/{id}/voip-token` -> 204.
  `DELETE /devices/{id}/push-token` (logout / notifications off) also clears the VoIP token and `PushRingCalls`.
- `PUT /devices/{id}/push-token` accepts optional `"ringCalls": true|false` (default false) and stores it in
  `PushRingCalls`. Only meaningful with `platform: "fcm"`; ignored (stored false) for other platforms.

### 1.2 Pending calls (`MessengerHub.RelayCallSignalAsync`)
Offer to an OFFLINE target, not muted (R8):
- Parse the offer payload envelope `{"v":1,"callId":"...","payload":"..."}`. If it does not parse or `callId` is
  missing/longer than 64 chars -> today's path (`unavailable` + `ForCall` alert push).
- If the target can ring (R2): store `PendingCall { CallId, CallerDeviceId, TargetDeviceId, BusinessGroupId,
  Signals: [(signalType, payload)], CreatedAt }` keyed by `(target, callId)`, absolute expiry 45 s; reply to the
  caller `CallSignal { senderId: target, signalType: "ringing", payload: <offer envelope echoed>, businessGroupId }`;
  send the ring push (1.3). Several pending calls per target are allowed (different callers).
- Else: today's path, unchanged.
Other signals to an offline target:
- `ice-candidate` whose envelope `callId` matches a pending call from the SAME caller -> appended (cap 64 signals,
  extra dropped). Otherwise dropped as today.
- `hangup` matching a pending call from the same caller -> remove it, write tombstone `(target, callId)` 2 min, send
  Android `call_cancelled` push if the target is an FCM ring device.
- 45 s expiry -> tombstone as well (use a PostEvictionCallback or check expiry lazily; must be covered by a test).
On callee hub connect (`OnConnectedAsync`, after `SendPendingAsync`) and in a new hub method
`RequestPendingCalls()` (idempotent, for an app that registered its listeners late):
- For each pending call of this device: send its signals in order as `CallSignal { senderId: caller, signalType,
  payload, businessGroupId }`, then remove it (delivered once).
- For each tombstone of this device: send `CallSignal { senderId: caller, signalType: "cancelled", payload:
  "{\"v\":1,\"callId\":\"...\",\"payload\":\"\"}", businessGroupId }`, then remove it.
Hub `DeclinePendingCall(string callId)`: caller device = authenticated device; removes the pending call addressed to
it with that callId (no-op if none) and, if the caller is online, sends them `CallSignal { senderId: callee,
signalType: "hangup", payload: {"v":1,"callId":"...","payload":"declined"}, businessGroupId }`.
Business calls (`BusinessCallSignal`) go through the same relay and keep all existing policy checks; the pending call
carries `BusinessGroupId` and delivery repeats it.

### 1.3 Ring pushes (`PushNotificationService`, `PushPayloads`, senders)
- New `PushTypes.CallCancelled = "call_cancelled"`. `PushNotification` gains optional `CallId`.
- iOS VoIP (`ApnsSender`, new method or flag): `POST /3/device/<VoipPushToken>`, headers `apns-push-type: voip`,
  `apns-topic: <BundleId>.voip`, `apns-priority: 10`, `apns-expiration: 0`; body
  `{"aps":{},"type":"incoming_call","callId":"...","conversationId":"...","v":"1"}`. 400 BadDeviceToken / 410
  Unregistered -> clear `VoipPushToken` only.
- Android ring (`FcmSender`): data-only message, NO `notification` block:
  `{"message":{"token":..., "android":{"priority":"high","ttl":"45s"}, "data":{"type":"incoming_call","callId":...,
  "conversationId":...,"v":"1"}}}`; `call_cancelled` same shape with `type: "call_cancelled"`.
- A ring push replaces the alert `incoming_call` push for ring-capable devices (never both).
- Golden tests in `PushPayloadsTests` for the three new bodies; sender header tests for voip.

### 1.4 Tests (integration, Testcontainers, existing patterns)
Ring path for iOS-voip and Android-ringCalls devices (caller gets `ringing`, fake sender saw exactly one ring push, no
alert push); legacy path unchanged for a device without capability and for a muted conversation; callee connect
receives offer + buffered ICE in order exactly once; caller hangup -> callee connect gets `cancelled` (+ Android
`call_cancelled` push); expiry -> `cancelled`; `DeclinePendingCall` -> caller gets `hangup` "declined" and callee
connect gets nothing; voip-token endpoints (self-only 403, invalid 400, DELETE push-token clears both); business call
pending path keeps policy checks. Update AGENTS.md endpoint table + the notifications spec N7 line.

## 2. App contract (`feat/call-ringing-app`)

Package: `flutter_callkit_incoming` (MIT; CallKit + PushKit on iOS, full-screen call notification on Android) unless
it proves unusable, then native CallKit/PushKit in `AppDelegate.swift` + `flutter_local_notifications` full-screen
intent. Pin the version.
- iOS: `UIBackgroundModes` += `voip` (and `audio` if the package requires it for CallKit audio). PushKit registration in
  `AppDelegate` (`PKPushRegistry` for `.voIP`); on `didReceiveIncomingPushWith` report the call to CallKit
  SYNCHRONOUSLY in native code before the completion handler (UUID from `callId` if it is a UUID, otherwise a
  deterministic UUIDv5 of it), caller name = "Jay", handle generic, `supportsVideo` false is fine. VoIP token ->
  `PUT /devices/{id}/voip-token` whenever it changes and after login; `DELETE` together with push-token on logout /
  notifications off. Audio: flutter_webrtc must use the CallKit-activated audio session (configure
  `RTCAudioSession` manual audio / follow the package's WebRTC notes); test plan item for TestFlight.
- Android: push-token registration sends `ringCalls: true`. `firebase_messaging` background handler: `incoming_call`
  data message -> show the package's full-screen incoming call (channel "calls", localized "Incoming call"),
  `call_cancelled` -> end it + local "Missed call". Manifest: `USE_FULL_SCREEN_INTENT`, and whatever the package
  requires (foreground service type `phoneCall` etc.). Android 14+: if full-screen intent permission is not granted,
  the package falls back to a heads-up notification; add a Settings -> Notifications row that opens the system
  setting when `canUseFullScreenIntent` is false (localized).
- Dart flow (both platforms), in a `CallRingCoordinator` (testable without plugins: the plugin sits behind an
  interface with a fake in tests):
  - Accept from CallKit / notification -> make sure SignalR is connected, call hub `RequestPendingCalls()`, wait up to
    10 s for the `offer` with that `callId`, then answer it through `WebRtcManager` WITHOUT showing the in-app ringing
    UI, and navigate to the call screen. Timeout -> end the CallKit call, show "Call ended" / missed.
  - Decline -> hub `DeclinePendingCall(callId)` (connect first), end the CallKit call.
  - `cancelled` signal for a ringing callId -> end the CallKit call, local "Missed call" notification.
  - Call ends in the app (hangup either side, failure) -> end the CallKit call for that callId. Mute/hold from the
    system UI -> `WebRtcManager` mute.
  - Caller side: `ringing` signal = keep ringing, show localized "Ringing..." status instead of "Calling...". Do NOT end
    the call (only `unavailable` ends it early, as today).
  - An offer arriving while the app is in the foreground keeps today's in-app ringing UI (no CallKit), unless a CallKit
    call for that callId is already reported (then it is the accept path above).
- l10n: every new string in all 19 ARB files (`untranslated-messages-file` must stay `{}`).
- Tests: coordinator unit tests (accept -> answer without in-app ringing, accept timeout, decline -> hub call,
  cancelled -> end + missed notification, in-app hangup -> end CallKit), WebRtcManager `ringing` handling, push
  registration sends `ringCalls` on Android and voip token on iOS (fakes), l10n guards.

## 3. Release / ops
No new Apple asset (the APNs `.p8` key with token auth covers `cz.zcloud.jay.voip`; background modes are not
entitlements, the App Store profile stays valid). Server settings unchanged. Manual acceptance on TestFlight + an
Android build: locked iPhone rings via CallKit, answer -> audio both ways; decline -> caller sees declined; caller
hangs up while ringing -> missed call; Android locked -> full-screen ringing.
