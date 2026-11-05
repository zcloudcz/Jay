# Contract between the server and the clients/bots (feat/bot-conversations)

Both sides code against this; do not change names without updating this file.

## GET /groups/{groupId}  (existing, member-gated) gains two fields

```json
{
  "...existing fields...": "...",
  "botTalk": {
    "mode": "off",                    // "off" | "all" | "selected"
    "allowedBotDeviceIds": [],        // Guid strings, meaningful for "selected"
    "maxBotTurns": 5,                 // 1..50
    "pauseMinutes": 30,               // 0..1440
    "updatedAt": "2026-11-05T10:00:00Z" // null when never changed
  },
  "myMute": { "mode": "off", "until": null }   // caller device's mute of this group
}
```

## PUT /groups/{groupId}/bot-talk   (admin only, same gate/status codes as adding a member)

Body: `{ "mode": "selected", "allowedBotDeviceIds": ["..."], "maxBotTurns": 5, "pauseMinutes": 30 }`
- 200 + the `botTalk` object above.
- 400 problem when: mode unknown, numbers out of range, an id is not a current member with `isBot = true`.
- Removing a member removes it from `allowedBotDeviceIds`.
- After a change every member device gets the existing "group changed" hub hint (same one add/remove member uses) so
  clients and bots re-read the group.
- Hint (server implementation note): there was no group hint before this feature, so the server added the hub event
  `GroupChanged` with payload `{ "groupId": "..." }`. It is sent after PUT bot-talk, PUT members and DELETE members to
  every online member device and their linked companions (a removed member gets it too). It carries no data; on receipt
  re-read `GET /groups/{groupId}` and `/members`. Offline devices get nothing and re-read on start.
- Omitted `maxBotTurns` / `pauseMinutes` keep their current values; omitted `allowedBotDeviceIds` = `[]`. 400 bodies are
  `application/problem+json` with an extra `error` code: `invalid_mode`, `invalid_max_bot_turns`,
  `invalid_pause_minutes`, `not_a_bot_member`.

## Mute (per caller device)

- `PUT /groups/{groupId}/mute`  body `{ "mode": "off" | "bots" | "all", "until": null | ISO-8601 }` -> 204 (member-gated).
- `PUT /mutes/direct/{peerDeviceId}` same body -> 204; mutes the 1:1 conversation with that peer's identity (all of the
  peer's linked devices; server resolves the peer's primary device like delivery does).
- `GET /mutes` -> `[{ "groupId": "..."|null, "peerDeviceId": "..."|null, "mode": "...", "until": ... }]` for the caller.
- Server notes: `mode: "off"` deletes the mute; expired mutes are reported as off (`myMute`) or omitted (`GET /mutes`).
  `peerDeviceId` in `GET /mutes` is the peer's PRIMARY device. Group mute is gated by identity (a companion may mute a
  group of its primary, for itself). Errors: 400 problem `invalid_mode`, direct mute 404 unknown peer, 400
  `cannot_mute_self` for a device of the caller's own identity.
- Push: `PushNotificationService` is skipped for a recipient when its mute for that conversation is `all`, or `bots` and the
  sender device `isBot`; expired `until` = not muted. Messages are still queued and delivered; only the push is skipped.

## GET /groups/{groupId}/members (existing) already returns deviceId, role, userHandle, displayName, isBot. Unchanged.
