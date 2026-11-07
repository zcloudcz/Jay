# Chat extras: search, pinned messages, polls (contract)

Status: built on `feat/chat-extras` (app, `calltype_core`, bots; no server change). Not released.

Three small chat features, researched against WhatsApp and Discord. All three live in end-to-end
encrypted 1:1 chats and groups. The server is an opaque relay and does not change: pins and votes
are encrypted control messages exactly like reactions
(`2026-11-07-message-reactions.md`), a poll is an encrypted message with a fallback text exactly
like encrypted media (`2026-11-07-encrypted-media.md`, rule M7). Public channels keep their own
server-side (plaintext) polls; that path is not reused.

## Decisions

| Topic | Decision |
|---|---|
| Search: where | Client only, over the local drift database (the server has no plaintext). Entry points: a search icon in the chat list app bar (all conversations) and a search icon in an open chat (that chat only). |
| Search: what | Text messages, the question and options of a poll and the caption of encrypted media. Not searched: deleted messages (tombstones), control rows, call log lines, device notices, inline file attachments (the body is base64 data; decoding it per search is too slow), names of files. |
| Search: how | A scan in Dart over the candidate rows, newest first, in pages of 500, stopping at 200 hits. Matching is case-insensitive and ignores Latin diacritics ("prilis" finds "Příliš"). WHY not SQL `LIKE`: SQLite's `LIKE` folds case for ASCII only (Czech "Ř" vs "ř" would not match) and a leading `%` cannot use an index anyway. WHY not FTS5: a virtual table means a migration, triggers for edit / delete / tombstone and the web build's sqlite3.wasm build options; not worth it for v1. No schema change. |
| Search: result | Conversation name (global search), sender ("You" or the contact / member name), a snippet around the first match with the match in bold, and the date. Tapping opens the chat scrolled to that message and highlights it briefly. |
| Jump to a message | Reuses the anchor of the jump-to-latest list (`ChatMessageList`): the target becomes the center sliver, so no item heights must be known. Used by search results and pins. |
| Pins: who | Any member of the conversation may pin and unpin (WhatsApp default). The pinner is the AUTHENTICATED sender identity. |
| Pins: cap | At most 3 pinned messages per conversation (like WhatsApp). Pinning a 4th: the app asks, then first sends an unpin of the oldest pin and then the new pin. Receivers also show only the 3 most recently pinned, so a conversation can never show more. |
| Pins: expiry | None in v1 (WhatsApp offers 24 h / 7 d / 30 d). |
| Pins: ordering | Last writer wins per (conversation, target) by the payload's `createdAt` in milliseconds; an equal timestamp is applied (same sender, same ordered ratchet). An unpin is stored as a row with `pinned = false`, so an older pin delivered late cannot bring it back. |
| Pins: UI | A bar under the app bar shows the newest pin (preview, "1 of 3"). Tap: jump to that message, then the bar moves to the next older pin (cycles). The list icon opens all pins (jump / unpin). Pin / Unpin is in the message menu. No "X pinned a message" line in v1. |
| Polls: shape | Question (1-300 characters), 2-10 options (1-100 characters each, distinct), single or multiple choice. No closing, no anonymous polls, no adding options later in v1. |
| Polls: votes | One current vote per person (identity) per poll: a set of option indexes, empty = vote withdrawn. Changing a vote sends the whole new set. Last writer wins per (poll, voter) by `createdAt` ms, ties applied, the withdrawal kept as a row. |
| Polls: results | Everyone sees live totals and who voted for what at any time (members already see each other's messages, and Signal makes it end to end; the names are the same labels as above the bubbles). The creator votes like everybody else. |
| Polls: notifications | A new poll notifies like a message ("📊 question"). Votes and pins never notify, never create a row, never bump `unreadCount` or `lastMessageAt`. |
| Business conversations | No pins, no polls in v1 (fail closed like reactions, edit and delete: the archiver would have to record them). The app hides the actions and refuses to send; a receiver drops them. |
| Own other devices | Get pins, polls and votes through the sender copy of the fan-out (`to` names the 1:1 conversation) and apply them under the own identity. |
| Sender | Applies its own pin / vote locally at once (optimistic). If the send fails, the previous state is restored unless the user changed it again meanwhile. A poll is a normal outgoing row (`sending`, retry). |
| Delete | Delete for everyone (tombstone) and delete for me remove the message's pins and, for a poll, its votes. Wiping a removed companion and "reset for linking" remove all pins and votes. |
| Forward / copy / edit | A poll cannot be forwarded, copied or edited. It can be replied to (quote "📊 question"), reacted to, pinned and deleted. |
| Backup | Pins and votes are part of the encrypted backup (`pins`, `pollVotes` arrays, additive). A poll row is written into the backup as `type: "text"` with the fallback text in `body` and the poll in an additive `poll` key, so an older app restores it as text instead of failing the whole restore on an unknown type. |

## Wire shapes

Same outer payload as every message (inside the E2E envelope):
`{v: 1, id, type, body, groupId, groupName, to (1:1 only), createdAt}`. `body` always stays a
STRING. Shared code (app and bots): `calltype_core/lib/messaging/pin.dart` and `poll.dart`.

### Pin (`type: "pin"`, control message)

```json
{
  "v": 1,
  "id": "<new message id>",
  "type": "pin",
  "body": "{\"targetId\":\"<message id>\",\"pinned\":true}",
  "groupId": null,
  "groupName": null,
  "to": "<peer identity id, 1:1 only>",
  "createdAt": "2026-11-08T10:15:00.123Z"
}
```

- `targetId`: 1-64 characters. `pinned`: boolean, `false` = unpin.
- Receiver: an invalid body is acked and dropped. A target that is known must live in the SAME
  conversation and not be a tombstone, a call log line, a device notice or a control row; a target
  not (yet) known is stored and shows only once a message with that id exists in this
  conversation. Redelivery is recognised by the `control:<messageId>` marker.

### Poll (`type: "text"` + `poll`)

```json
{
  "v": 1,
  "id": "<poll id = message id>",
  "type": "text",
  "body": "📊 Lunch?\n• Pizza\n• Sushi\n(Update Jay to vote in this poll.)",
  "poll": {"v": 1, "question": "Lunch?", "options": ["Pizza", "Sushi"], "multiple": false},
  "groupId": "<group id or null>",
  "createdAt": "2026-11-08T10:15:00.123Z"
}
```

- `body` is the fallback text an older client shows (written in the sender's UI language).
- `poll.v` must be 1; `question` 1-300 characters after trimming; `options` 2-10 strings, each 1-100
  characters after trimming, no two equal; `multiple` boolean. Anything else: the `poll` key is
  ignored and the message stays plain text (never dropped, never blocks the inbox), like an
  invalid `media` object. A message that carries a valid `media` object is media; `poll` is not
  read then.
- Stored locally as `messages.type = "poll"`, `body` = canonical JSON
  `{"v":1,"question":...,"options":[...],"multiple":...}`.

### Vote (`type: "poll-vote"`, control message)

```json
{
  "v": 1,
  "id": "<new message id>",
  "type": "poll-vote",
  "body": "{\"pollId\":\"<poll id>\",\"options\":[0,2]}",
  "createdAt": "2026-11-08T10:15:00.123Z"
}
```

- `pollId`: 1-64 characters. `options`: distinct integers 0-9 (sent sorted); `[]` withdraws the
  vote. Body at most 1024 characters.
- Receiver: invalid = acked and dropped. A known poll must be in the SAME conversation, of type
  `poll` and not deleted; every index must be below its option count, and a single-choice poll
  takes at most one. A vote for a poll not (yet) known is stored and validated when shown (an
  index the poll does not have is ignored then, a single-choice vote with several indexes is
  ignored).

## Local storage (schema v9)

| Table | Columns | Key |
|---|---|---|
| `message_pins` | `conversation_id`, `message_id`, `pinned` (bool), `pinned_by` (identity), `changed_at` (ms) | (`conversation_id`, `message_id`) |
| `poll_votes` | `poll_id`, `voter_id` (identity), `conversation_id`, `options` (JSON int list, `[]` = withdrawn), `voted_at` (ms) | (`poll_id`, `voter_id`) |

Migration v8 -> v9 creates both tables; nothing else changes. Search adds no table and no index.

## Compatibility

| Receiver | Behaviour |
|---|---|
| Old app (before this change) | Poll: shows the fallback text (question, options, "Update Jay to vote"). `pin` / `poll-vote`: throws "Unsupported message type" before storing anything, so it stays queued on the server for that device until the 30-day TTL (the accepted cost of `edit`, `delete` and `reaction`). Nothing garbled is ever shown. A backup made by the new app restores on an old app with polls as text and without pins / votes. |
| `calltype_bot` | Acks and ignores `pin` and `poll-vote` (every non-text type). A poll arrives as a normal text message (fallback body); new: `BotMessage.poll` carries the parsed poll (null otherwise). |
| `hermes_bridge`, `a2a_bridge` | Use `calltype_bot`: pins and votes are ignored, a poll reaches the agent as its fallback text. |
| `jay_archiver` | Archives `pin` and `poll-vote` like a reaction (metadata only: kind `text`, size and SHA-256 of the body) so K01 "no ack without a durable write" holds; a malformed body is not acked. A poll is archived as the text message it is on the wire. The app sends none of them into business groups in v1, so this is defensive. |
| Server | Unchanged. An offline device gets the usual generic "New message" push for a pin or vote. |

## Limits

- Search scans the local history in Dart; very large histories (hundreds of thousands of rows)
  take noticeably longer than an FTS index would. Only the first 200 hits are listed. Inline file
  attachments and file names are not searched. Only messages on this device are searched
  (a fresh companion only has what it received since linking).
- No pin expiry and no "pinned a message" notice line; pins are not shown in the chat list.
- Polls cannot be closed, edited or forwarded and have no anonymous mode; votes of former members
  stay counted and show as an id when no name is known.
- Business conversations: no pins and no polls in v1.
- Old apps keep a pin or vote queued on the server until the TTL (as for reactions).
