# Contact sync and history transfer between own devices (contract)

Status: approved by the owner (2026-11-08, "implementuj a nasad"), on `feat/contact-sync` (built on `feat/chat-extras`).
Implemented on `feat/contact-sync` (core codecs, app, server tests); manual acceptance in
`docs/acceptance/contact-sync.md` (all NOT_RUN). Changes made during implementation are marked
"Implementation note".
This is spec 3 (state sync, contacts part) plus spec 2 (history transfer) of the roadmap in
`2026-10-13-multi-device-sync-design.md`. Read, delete-for-me and call ringing stay in spec 3
for later.

## What the owner asked for

1. When I link a device, I see my contacts on it.
2. I can move my messages from another of my devices to it, for example by scanning a QR code.
3. When I rename a contact on one device, the new name shows on all my devices.

## Today (multi-device v1)

- Only messages are mirrored to own devices (fan-out, `to` names the 1:1 conversation).
- Contacts are a local table per device. `ContactsController.renameContact` writes only the
  local `contacts.display_name`. A device is linked only while EMPTY, so a fresh companion has
  no contacts: conversations it learns from new messages show the raw identity id as title.
- History before linking is never transferred.

## Decisions

| Topic | Decision |
|---|---|
| Transport for sync | New encrypted control messages addressed to the OWN identity: `SendReliableDirectFanout(recipientPrimaryId = own primary, ...)`. The hub then requires exactly the sender's other devices (it already computes `devicesOf([recipient, senderPrimary]) - sender`, and `OrgCommunicationPolicy` returns allowed for the same identity). Own devices get no push for it (existing rule). The server only relays ciphertext; it learns that an identity talks to itself, not what. No server code change expected; an integration test proves it (see Server). |
| Who may sync | Only a device of the SAME verified identity (`DeviceDirectory.identityOf(sender) == selfIdentityId`). Anything else is acked and dropped. Handled before conversation routing. |
| No other own device | A primary without companions sends nothing (the hub would refuse an empty fan-out). |
| Contacts after linking | The primary sends a full `contact-sync` snapshot to own devices as soon as it has PUT a list with a new companion, and again when a companion asks for it (`contact-sync-request`, sent by a companion right after it switched to companion mode, so a lost snapshot is repaired). Any device may also offer "Sync contacts now" in Settings > Devices. |
| What a snapshot carries | Every contact row: `deviceId`, `userHandle`, `displayName`, `isBot`, `addedAt`, `nameChangedAt`. Plus every conversation header (`id`, `type`, `title`, `organizationId`, `organizationName`) WITHOUT messages, so the chat list of a new device shows all chats with the right names before any message arrives. Not carried: identity keys, `verified`, sessions, device lists, drafts, mutes (mutes are already server side). |
| Ongoing changes | Every local add or rename of a contact sends `contact-sync` with `op: upsert` for that one contact. Clearing a name is an upsert with `displayName: null`. There is no contact delete in the app today; when one is added it sends `op: remove` (kept as a tombstone, same reason as reactions). |
| Conflicts | Per contact, the name is last writer wins by `nameChangedAt` (ms since epoch, sender's clock), ties broken by the larger name (code unit order, no name is the smallest). A snapshot entry is applied field by field with the same rule, so an older snapshot cannot undo a newer rename. A contact unknown locally is inserted. `userHandle` and `isBot` are taken only when the contact is new locally (they come from the server lookup and do not change). Implementation note: the first draft broke ties by the larger sender device id. That is not well defined: a snapshot relays names written by OTHER devices, so the sender of a message is not the writer of the name, and the receiver does not store who wrote its local name. Comparing the names needs no extra state and converges on every device whatever the arrival order. |
| `verified` | Not synced in this version. Each device verifies the safety number itself. (Syncing it safely needs the verified key fingerprint and a comparison with the local pin; out of scope.) |
| History transfer: trigger | On the device that should RECEIVE (target): Settings > Devices > "Transfer messages from another device". It shows a QR code (and the same content as a copyable text code for devices without a camera: web, Windows, Linux, see `canScanLinkCodes`). On the device that HAS the history (source, any own device, usually the phone): "Send my messages to another device" > scan or paste. The source shows "Chats: N, about X MB. Transfer them to <device>?" and starts after confirmation. The entries show on a companion and on a primary with companions, next to "Sync contacts now". |
| QR content | `calltype://history-transfer?v=1&d=<target deviceId>&t=<transferId>&k=<target ephemeral X25519 public key, base64url>`. `transferId` = random 128 bit. The ephemeral key pair lives in memory of the target only while the QR is shown (max 15 minutes). |
| Why a QR at all | Both devices already share Signal sessions, but the QR is the user's intent and an out-of-band key: the archive key is wrapped for the ephemeral key that came through the camera, so neither the server nor another own device (for example a stolen browser that is still listed) can redirect or read the transfer. The source refuses a target that is not in its own verified device list. |
| Archive | The backup JSON (`version: 1`, same writer as `BackupController`: contacts, conversations, messages, reactions and, once merged, pins and poll votes), gzip-compressed, then encrypted and uploaded with the encrypted media pipeline (`/media`, AES-256-GCM per chunk, `Media:MaxFileBytes` cap, 72 h retention). Media messages carry only their `media` objects, as in the backup: the files download again while the server copy lives. Inline files are part of the message bodies. |
| Key delivery | The source sends `history-transfer` through the own-identity fan-out: `{transferId, targetDeviceId, mediaId, size, sha256, sourceEphemeralKey, wrappedKey}`. `wrappedKey` = AES-256-GCM(HKDF-SHA256(X25519(source eph, target eph), info "CallType-HistoryTransfer-v1"), archive key and nonce). Every other own device ignores a `transferId` it did not create. Exact encoding: `transferId` 32 lowercase hex characters; `size` and `sha256` describe the plaintext (gzip) archive, `sha256`, `sourceEphemeralKey` (32 raw bytes) and `wrappedKey` are standard base64; the HKDF salt is empty; `wrappedKey` is 12 byte GCM nonce, ciphertext of key (32) + media nonce prefix (7), 16 byte tag. The archive uses the default media chunk size (4 MiB), so the body carries no chunk size. In the QR code `k` is base64url without padding. |
| Import | The target downloads, checks size and SHA-256, decrypts, decompresses and imports with the backup import rules (insert-or-ignore, so messages it already has stay, lenient for reactions/pins/votes, unread counts 0). A non-empty device is allowed: it is a merge, never a wipe. Contacts in the archive go through the same LWW rule as a snapshot. |
| Size and scope v1 | Everything, one archive. The source shows the estimate before sending. Above `Media:MaxFileBytes` the source refuses with a message (no partial transfer in v1). |
| Progress, failure | Both sides show progress. Cancel on either side deletes the upload (source) or the temporary file (target). A failed transfer is restarted from a new QR; there is no resume in v1. After a successful import the target sends `history-transfer-done {transferId}` so the source can delete the media object at once instead of waiting for the retention. |
| Business conversations | Contacts and conversation headers sync as everything else. History transfer includes business conversations only to a device that may take part in them: v1 business is primary-only, so a companion target gets their headers but not their messages, consistent with today. |
| Backup | `contacts` rows gain `nameChangedAt` (additive; older backups default to 0). Implementation note: they also gain `isBot` (older backups: false) and conversations gain `organizationId` / `organizationName`, so a transferred archive keeps the bot badge and the business banner; both additive. The writer is one function (`buildBackupData`) shared by the cloud backup and the transfer. |

## Wire shapes

All inside the E2E envelope, outer keys as for every message: `{v: 1, id, type, body, groupId:
null, to: <own identity id>, createdAt}`. `body` stays a STRING. Shared code:
`calltype_core/lib/messaging/contact_sync.dart`, `history_transfer.dart`.

`contact-sync`, body JSON:

```json
{"op": "upsert",
 "contacts": [{"deviceId": "<guid>", "userHandle": "CT-XXXX-XXXX", "displayName": "Mom",
               "isBot": false, "addedAt": "2026-10-01T08:00:00Z", "nameChangedAt": 1762590000123}]}
{"op": "snapshot", "contacts": [...], "conversations": [{"id": "...", "type": "group", "title": "Team",
 "organizationId": null, "organizationName": null}]}
{"op": "remove", "deviceIds": ["<guid>"], "changedAt": 1762590000123}
```

- At most 2000 contacts and 2000 conversations per message; a larger snapshot is split into
  several `snapshot` messages (each applied on its own, order does not matter).
- `displayName` null or 1-100 characters after trimming; `userHandle` matches `CT-XXXX-XXXX`;
  `deviceId` a GUID. An invalid entry is skipped, the rest applied.

`contact-sync-request`, body `{}`.

`history-transfer`, body as in Decisions; `history-transfer-done`, body `{"transferId": "..."}`.

Receiver: all four are control messages (no row, no unread, `control:<id>` marker), accepted only
from an own device. Unknown or invalid: ack and drop.

## Local storage

- `contacts.name_changed_at` (int ms, default 0). Schema v10 (this branch is built on
  `feat/chat-extras`, which has v9).
- Tombstones for removed contacts: `backupState` key `contact-removed:<deviceId>` = ms, until a
  contact delete exists in the app.
- Transfer state (source and target) in memory plus temporary files under the media storage;
  nothing permanent.
- Pending own-device messages: `backupState` key `ownsync:<messageId>` = exact envelopes and
  payload, resent on reconnect (no messages row, unlike a chat outbox). Own devices that sent a
  sync message: `ownsync-seen:<deviceId>`, used for the "Update Jay on all your devices" hint.
  Both are cleared by the companion wipe.

## Server

- No new endpoint, no setting. Add integration tests to `FanoutHubTests`: a direct fan-out
  addressed to the caller's own primary (1) from the primary reaches every companion, (2) from
  a companion reaches the primary and the other companions, (3) sends no push to own devices,
  (4) with business mode on and the user enrolled under `RequireBusinessConversations`, is still
  allowed. If any of these fails, the contract gets a dedicated hub method instead; decide then.
- AGENTS.md needs no settings row.

## Compatibility

| Receiver | Behaviour |
|---|---|
| Own device on an old app | Throws "Unsupported message type" for the new types, the message stays queued until the 30-day TTL (accepted cost, as for reactions). It is the user's own device: the UI on the new app says "Update Jay on all your devices" when a sync is sent to a list with devices that never answered a `contact-sync-request` (best effort). |
| Contacts, bots, archiver | Never receive these messages (own identity only). |
| Old backups | Restore with `nameChangedAt` 0. |

## Tests (definition of done)

- Core: codec tests for all four bodies (valid, invalid, limits, split snapshot).
- App flow tests with the fake hub (phone + web + second web): link, then the web shows the
  phone's contacts and chat titles; rename on web reaches phone and second web; concurrent
  renames end with the same name everywhere (LWW); a `contact-sync` from a non-own device is
  dropped; history transfer happy path; wrong ephemeral key / not-own target / tampered archive
  (SHA mismatch) refused; transfer into a non-empty device merges without duplicates; cancel
  cleans up.
- Widget tests: QR / text code screen, source confirmation, progress, error texts.
- Server: the four hub tests above.
- l10n in all 19 ARB files, `build/l10n_untranslated.json` = `{}`.
- Manual acceptance list in `docs/acceptance/contact-sync.md` (phone + web + Windows desktop
  without camera, old app on one device).

## Limits

- `verified` marks, drafts and read state do not sync (read state and delete-for-me stay in
  spec 3).
- No partial or resumable transfer; one archive up to `Media:MaxFileBytes`.
- Media files are transferred only as references: after the server retention (72 h) old media
  stay unavailable on the new device, exactly as after a backup restore.
- Moving the PRIMARY role to a new phone is not part of this (identity recovery, spec 4).
- An own device on an old app misses syncs until it is updated.
