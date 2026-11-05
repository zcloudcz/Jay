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

## Mute (per caller device)

- `PUT /groups/{groupId}/mute`  body `{ "mode": "off" | "bots" | "all", "until": null | ISO-8601 }` -> 204 (member-gated).
- `PUT /mutes/direct/{peerDeviceId}` same body -> 204; mutes the 1:1 conversation with that peer's identity (all of the
  peer's linked devices; server resolves the peer's primary device like delivery does).
- `GET /mutes` -> `[{ "groupId": "..."|null, "peerDeviceId": "..."|null, "mode": "...", "until": ... }]` for the caller.
- Push: `PushNotificationService` is skipped for a recipient when its mute for that conversation is `all`, or `bots` and the
  sender device `isBot`; expired `until` = not muted. Messages are still queued and delivered; only the push is skipped.

## GET /groups/{groupId}/members (existing) already returns deviceId, role, userHandle, displayName, isBot. Unchanged.
