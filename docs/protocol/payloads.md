# Payloads (inside the envelope)

The plaintext of every envelope is one UTF-8 JSON object, the payload.
Sources of truth: the codecs in `src/client/calltype_protocol/lib/messaging/`,
the app's sender (`ChatController`) and receiver (`MessageInboxService`),
the bot runtime (`src/bots/calltype_bot`) and the feature specs linked per
type. This file is the summary a foreign implementation needs; where a spec
has more detail it is linked, not copied.

General rules:

- All keys are additive: a receiver ignores keys it does not know.
- Invalid OPTIONAL data degrades to "absent" (the message still shows its
  text); an invalid control message is acknowledged and dropped.
- A receiver that does not know a `type` must NOT acknowledge the message
  (the app throws, the message stays queued on the server). That is how old
  clients behave for types added later.

## Common payload (version 1)

| Key | Type | Required | Meaning |
|---|---|---|---|
| `v` | int | yes | `1`. Any other value: the message is rejected. |
| `id` | string | yes | Message id (UUID). Must equal the outer `messageId` of the delivery. |
| `type` | string | no, default `text` | One of the types below. |
| `body` | string | yes | Type-specific; always a string (JSON-in-a-string for structured types). |
| `groupId` | string or null | yes for groups | Must equal the outer `groupId` (null for 1:1); a mismatch is rejected. |
| `groupName` | string or null | no | Group title for a receiver that does not know the group yet. |
| `createdAt` | string | no | ISO 8601 UTC send time on the sender's clock. Missing or invalid: receive time. |
| `to` | string | own copies | Direct conversation id for a copy sent to the sender's OWN other devices (multi-device). Honoured only when the sender is a verified device of the receiver's own identity. |
| `replyTo` | object | no | `{"id", "senderId", "preview"}`, all strings. The quote is the sender's claim; receivers cut `preview` to 140 characters and drop a malformed `replyTo` silently. |
| `forwarded` | bool | no | `true` marks a forwarded message. |
| `mentions` | list | no | Identity ids (lower case), max 50, `text` only. |
| `actions` | list | no | Bot buttons `{"id", "label"}`, max 8, id `^[A-Za-z0-9_.:-]{1,64}$`, label 1..40 characters. Rendered only under a BOT's message. |
| `action` | object | no | Button press `{"messageId", "id"}` on a `text` message; `body` = the label. |
| `editOf` | string | `edit` | Target message id. |
| `media` | object | no | Encrypted media descriptor, see `media` below. |
| `poll` | object | no | Poll, see `poll` below. |

Mentions, buttons and edits: `docs/superpowers/specs/2026-11-05-agent-messaging-contract.md`
(section 1) and `lib/messaging/agent_payload.dart`.

Example:

```json
{"v":1,"id":"3f0c6c1e-6a43-4b8e-9b1f-0d7c1c2f5a10","body":"Hi @Bob","type":"text",
 "groupId":null,"groupName":null,"createdAt":"2026-11-08T10:15:00.000Z",
 "to":"8a1d...","mentions":["8a1d..."],"replyTo":{"id":"...","senderId":"...","preview":"earlier text"}}
```

## Types

### `text`

`body` = the text. May carry `mentions`, `actions` (from bots), `action`,
`replyTo`, `forwarded`, and the `media` or `poll` objects below.

### `media` (sent as `text` + `media`)

Sent as `type: text` with a human-readable fallback `body` (old clients show
it) plus a `media` object. A receiver that understands it stores a media
message; an invalid object or a newer `v` keeps the fallback text. Media wins
when a message carries both `media` and `poll`.

`media` (version 1): `v` (1), `id` (relay media id), `kind`
(`image`/`video`/`audio`/`voice`/`file`; unknown kinds are shown as `file`), `name`, `mime`, `size`
(bytes), `sha256` (base64), `key` (base64, 32 bytes), `nonce` (base64, nonce
prefix), `chunkSize`; optional `expiresAt` (ISO 8601), `durationMs`, `width`,
`height`, `thumbnail` (base64), `waveform` (base64), `caption`. Chunked
encryption, sizes and limits: `docs/superpowers/specs/2026-11-07-encrypted-media.md`.

### `poll` (sent as `text` + `poll`)

Same pattern: `type: text`, fallback `body`, plus
`"poll": {"v": 1, "question": "...", "options": ["...", "..."], "multiple": false}`.
2 to 10 distinct options, question 1..300 and options 1..100 characters,
already trimmed (an untrimmed value makes the poll invalid, the fallback text
stays). Not used in business conversations. Spec:
`docs/superpowers/specs/2026-11-08-chat-extras.md`, code `lib/messaging/poll.dart`.

### `poll-vote` (control)

`body` = JSON string `{"pollId": "<poll message id>", "options": [0, 2]}`:
sorted distinct option indexes; an empty list withdraws the vote. Per voter
the vote with the newest `createdAt` wins (an older one arriving late is
ignored).

### `file`

`body` = JSON string `{"name": "...", "data": "<base64 bytes>", "caption": "..."}`
(`caption` optional), at most 256 KiB of data. The older inline attachment;
new clients send `media`.

### `call-event` (business groups)

Sent by each participant when a call ends, to the group including the
auditor device. `body` = JSON string with exactly the 7 keys `callId`,
`role` (`caller|callee`), `peerDeviceId`, `startedAt`, `endedAt` (or null),
`media` (`audio|video`), `outcome` (`completed|missed|rejected|failed|unavailable`).
Spec: `docs/superpowers/plans/2026-09-18-business-mode-contracts.md`, section
"Call event wire format".

### `delete` (control)

`body` = id of the message to delete for everyone. Applied only when the
target is in the same conversation and the authenticated sender is the
target's sender. Never creates a message.

### `edit` (control)

`body` = the full new text, `editOf` = target id, optional `actions`
(present = replace the buttons, empty list = remove them, absent = keep).
Applied only to an existing, not deleted `text` message of the same sender,
and only if `createdAt` is newer than the last applied edit.

### `reaction` (control)

`body` = JSON string `{"targetId": "<message id>", "emoji": "<one emoji>"}`;
`emoji` = `""` removes the sender's reaction. Exactly one emoji grapheme, at
most 32 UTF-16 code units; target id at most 64 characters. Spec:
`docs/superpowers/specs/2026-11-07-message-reactions.md`, code
`lib/messaging/reaction.dart`.

### `pin` (control)

`body` = JSON string `{"targetId": "<message id>", "pinned": true}`;
`false` unpins. At most 3 pins per conversation are shown. Spec:
`docs/superpowers/specs/2026-11-08-chat-extras.md`, code `lib/messaging/pin.dart`.

### Own-device sync (control, only between devices of ONE identity)

Accepted only from a verified device of the receiver's own identity and only
in a direct (non-group) delivery; anything else is acknowledged and dropped.
Spec: `docs/superpowers/specs/2026-11-08-contact-sync.md`.

- `contact-sync`: `body` = JSON string, one of
  - `{"op": "upsert", "contacts": [Contact, ...]}`
  - `{"op": "snapshot", "contacts": [Contact, ...], "conversations": [Conversation, ...]}`
  - `{"op": "remove", "deviceIds": ["..."], "changedAt": <ms>}`

  `Contact = {"deviceId", "userHandle", "displayName" (string or null),
  "isBot", "addedAt" (ISO 8601), "nameChangedAt" (ms, 0 = never)}`;
  `Conversation = {"id", "type" ("direct"|"group"), "title",
  "organizationId", "organizationName"}`. At most 2000 entries per list; a
  bigger snapshot is split into several messages. Identity keys, `verified`
  and sessions are never synced. Code: `lib/messaging/contact_sync.dart`.
- `contact-sync-request`: `body` = `"{}"`; asks the primary for a snapshot.
- `history-transfer`: `body` = JSON string `{"transferId", "targetDeviceId",
  "mediaId", "size", "sha256", "sourceEphemeralKey", "wrappedKey"}` (binary
  fields base64). `wrappedKey = AES-256-GCM(HKDF-SHA256(X25519(source
  ephemeral, target ephemeral), salt empty, info "CallType-HistoryTransfer-v1",
  32), archive key (32) || media nonce prefix (7))` as `nonce || ct || tag`.
  The target's ephemeral key comes from its QR code
  `calltype://history-transfer?v=1&d=<deviceId>&t=<transferId>&k=<key>`
(`k` = base64url without padding).
  Code: `lib/messaging/history_transfer.dart`.
- `history-transfer-done`: `body` = JSON string `{"transferId": "..."}`.
- `read-state`: `body` = JSON string `{"v": 1, "conversationId": "...",
  "readUpTo": <ms>}`: this identity has read the conversation up to the
  incoming message with that `createdAt` (ms since epoch). Receivers keep
  the maximum per conversation, lower their unread count to the incoming
  messages after it and cancel the conversation's notification when it
  reaches 0. Never raises an unread count. Spec:
  `docs/superpowers/specs/2026-11-09-auto-resend-read-sync.md`, code
  `lib/messaging/read_state.dart`.
- `chat-deleted`: `body` = JSON string `{"v": 1, "conversationId": "...",
  "deletedAt": <ms>}`: this identity deleted the conversation (on this side
  only, not for the other participants) at that moment. Receivers delete the
  messages of that conversation with `createdAt <= deletedAt` together with
  their reactions, pins and votes, and drop the conversation row when nothing
  is left; a later message survives. An unknown conversation is ignored. Spec:
  `docs/superpowers/specs/2026-11-09-delete-chats-contacts.md`, code
  `lib/messaging/chat_deleted.dart`.

## Idempotence

A message id is processed at most once per device: the receiver commits the
ratchet step together with the message row (or a `control:<id>` marker for
control messages) in one transaction, and acknowledges a redelivered id
without decrypting it again.
