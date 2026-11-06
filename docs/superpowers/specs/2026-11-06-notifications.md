# Notifications (design + contract, feat/notifications)

Status: approved by Martin 2026-11-06 ("implementuj vse. Firebase na konci nakonfigurujeme"). Prepared by Hermes Dev.
Branch `feat/notifications` (from `feat/channel-moderation`, released together). Every layer codes against this file.

## Why

Jay shows no notification anywhere today: the app has no local notifications, the server sends data-only FCM pushes,
the Firebase project does not exist yet, APNs is "not yet implemented", the web has no push service worker. A
messenger without notifications is not usable as a daily messenger.

## Decisions

| # | Decision | Why |
|---|---|---|
| N1 | Local notifications whenever the app process runs (foreground with another chat open, background, minimized, tray) on Android, iOS, macOS, Windows, Linux (`flutter_local_notifications`) and web (browser Notification API). Content: sender name + message preview, **preview on by default**, setting to hide it (then "New message"). | The app has the plaintext; WhatsApp/Signal default. Martin did not object to the default |
| N2 | Server pushes (device offline) are **visible, generic and localized**: "New message", "New message in a group", "Incoming call", "New post in a channel". No sender, no group name, no text: the server has no plaintext and names would leak metadata to Apple/Google. | E2E: server never sees content |
| N3 | Three providers, no Google needed for two of them: **Web Push** (RFC 8030 + VAPID, server-generated keys), **APNs** direct (HTTP/2, token auth `.p8`), **FCM** HTTP v1 (Android, existing sender; works as soon as Firebase is configured). | Firebase blocked on the company Google account; Martin: configure Firebase at the end |
| N4 | Collapse per conversation (FCM `android.notification.tag` + `collapse_key`, APNs `apns-collapse-id` + `thread-id`, Web Push `Topic`), so 20 messages = one notification per chat. | Lock-screen spam |
| N5 | Push only to offline devices (unchanged), respecting conversation mutes (unchanged) and channel post throttle (unchanged). Calls: an `offer` call signal to an offline device triggers an `incoming_call` push (high priority). | |
| N6 | Notification tap opens the conversation (`conversationId` in the push data = group id, or the sender's primary device id for 1:1; channel id for channel posts). The server already has this metadata. | |
| N7 | Out of scope: decrypting in the background for rich offline previews (Android isolate / iOS Notification Service Extension), CallKit/VoIP push and full-screen ringing, desktop push when the app is closed (no OS push channel without a store app), FCM topics for big channels. | Size; later |

## 1. Server contract

### 1.1 Registration
`PUT /devices/{id}/push-token` (existing route; now the caller must be device `{id}`, else 403, like the profile route).
Body `{"platform": "fcm"|"apns"|"webpush", "token": "<string>", "locale"?: "<BCP-47, e.g. cs or en-US>"}`.
- `fcm`: FCM registration token. `apns`: hex device token (64..200 hex chars, else 400 `invalid_token`).
  `webpush`: the browser `PushSubscription.toJSON()` serialized as a JSON string `{"endpoint","keys":{"p256dh","auth"}}`;
  endpoint must be `https://`, keys present, else 400 `invalid_token`. Max token length 2048.
- `locale` stored on the device (`Device.PushLocale`, max 16, default null = `en`); the generic texts are chosen by
  language prefix: `cs` -> Czech, else English.
- 204. `DELETE /devices/{id}/push-token` (self only) clears token, platform and locale -> 204 (logout / notifications off).
- Migration `AddPushLocale`: `Device.PushLocale` (string? max 16). `PushToken` max length 2048 if it had a smaller one.

`GET /push/webpush-key` (anonymous) -> 200 `{"publicKey": "<VAPID public key, base64url, uncompressed P-256>"}`, 404
when Web Push is not configured.

### 1.2 Config
- `Push:FcmServiceAccountJson` (existing).
- `Push:Apns:KeyId`, `Push:Apns:TeamId` (`DZR3FD9ZNT`), `Push:Apns:BundleId` (default `cz.zcloud.jay`),
  `Push:Apns:PrivateKeyP8` (PEM text of the `.p8`), `Push:Apns:UseSandbox` (default false; TestFlight + App Store =
  production). Empty KeyId/key = APNs disabled (log once).
- `Push:WebPush:PublicKey`, `Push:WebPush:PrivateKey` (base64url VAPID), `Push:WebPush:Subject` (default
  `mailto:martin@zcloud.cz`). Empty = Web Push disabled. Document `openssl`/tool command to generate keys in CLAUDE.md
  push section.

### 1.3 Payload (all providers)
Data keys (strings): `type` = `message` | `group_message` | `incoming_call` | `channel_post`, `conversationId`, `v` = `1`.
Visible part: title "Jay", body by type and language:
- `message`: cs "Nová zpráva", en "New message"
- `group_message`: cs "Nová zpráva ve skupině", en "New message in a group"
- `incoming_call`: cs "Příchozí hovor", en "Incoming call"
- `channel_post`: cs "Nový příspěvek v kanálu", en "New post in a channel"
Provider specifics:
- FCM: `message.notification {title, body}`, `android {priority: high, collapse_key: <conversationId>, notification
  {tag: <conversationId>, channel_id: "messages"|"calls"|"channels"}}`, `data` as above. 404/UNREGISTERED -> clear
  the device token (existing behaviour, keep).
- APNs: `POST /3/device/<token>`, headers `apns-push-type: alert`, `apns-topic: <BundleId>`, `apns-priority: 10`,
  `apns-collapse-id: <conversationId>` (max 64 bytes), body `{"aps": {"alert": {"title", "body"}, "sound": "default",
  "thread-id": <conversationId>, "mutable-content": 1}, "type", "conversationId", "v"}`. JWT ES256 provider token cached
  50 min. 410 or 400 `BadDeviceToken`/`Unregistered` -> clear token.
- Web Push: encrypted payload (RFC 8291 aes128gcm) JSON `{"title","body","type","conversationId","v","tag":
  <conversationId>}`, headers `TTL: 86400`, `Urgency: high`, `Topic: <conversationId hashed to 32 base64url chars>`.
  404/410 -> clear token. Use a maintained NuGet (e.g. `WebPush` / `Lib.Net.Http.WebPush`) or a small own
  implementation with tests against RFC 8291 test vectors.
- Calls: `RelayCallSignalAsync` with signalType `offer` (check the real name in code) and the target offline ->
  `incoming_call` push (not throttled, not muted unless the 1:1 mute mode is `all`).

## 2. App contract

- `flutter_local_notifications` for Android/iOS/macOS/Linux/Windows; web via `package:web` Notification API.
  Android channels `messages`, `calls`, `channels` (ids must match 1.3). Android 13 `POST_NOTIFICATIONS` permission.
- Show a local notification for every incoming message/call/channel post the app receives through SignalR or sync,
  unless: the conversation is open and the app is in the foreground and focused; the conversation is muted (existing
  per-device mute, same modes); the sender is this identity (own other device). Group by conversation (tag/thread),
  title = contact/group name, body = preview (first 120 chars; attachments/polls as a localized type label) or the
  generic text when previews are off. Tap -> open the conversation (also for server pushes using `conversationId`).
- Settings -> Notifications: enable notifications (registers/unregisters push via 1.1), show preview (default on),
  test notification button, per-platform status text (permission denied / not configured / active).
- Push registration per platform:
  - Android: FCM via `firebase_messaging` when Firebase is configured (`google-services.json` present at build time;
    build must keep working without it), `platform: fcm`.
  - iOS: native APNs token through a method channel in `AppDelegate` (`registerForRemoteNotifications`), NOT Firebase,
    `platform: apns`. `Runner.entitlements` with `aps-environment = production` wired into the Runner target; check the
    TestFlight workflow's manual signing still works (the "Jay App Store" profile must include Push; App ID has Push).
  - Web: service worker `web/push-sw.js` (scope `/`, must not break `/admin/` or the app) showing the push
    `notification` and focusing/opening `/#/chat/...` on click; subscribe with the key from `GET /push/webpush-key`,
    `platform: webpush`. Ask for permission only from a user gesture (Settings button or a one-time banner), never on load.
  - macOS/Windows/Linux: local notifications only (no push registration).
- Locale sent with registration = app locale.
- CI/deploy: optional secret `GOOGLE_SERVICES_JSON_BASE64` -> written to `android/app/google-services.json` before the
  Android build when set (deploy.yml + ci dev build); Gradle applies the Google services plugin only when the file
  exists. Document in CLAUDE.md push section with the Firebase steps that remain for the end (Android app
  `cz.zcloud.jay`, service account JSON -> `Push__FcmServiceAccountJson`).
- All strings via l10n in every locale.

## 3. Tests

Server: registration validation per platform, self-only, DELETE, webpush key endpoint, payload builders per provider
(golden JSON incl. collapse ids and locale texts), APNs JWT shape, Web Push encryption against RFC 8291 vectors, token
clearing on 410/404/Unregistered (fake HTTP handler), call push on offline offer, mute respected, online devices not
pushed (existing). App: notification decision logic (open conversation, muted, own device, preview off), payload ->
route on tap, settings flows with a fake platform layer, registration per platform with fakes. Web: SW file served and
its click handler logic covered by a small JS test or reviewed manually. Live: local compose + a real browser Web Push
subscription is not automatable here; verify payload delivery to a fake push endpoint in an integration test.
