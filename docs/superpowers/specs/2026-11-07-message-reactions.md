# Message reactions in chats (contract)

Status: built on `feat/message-reactions` (app, `calltype_core`, bots; no server change). Not released.

Emoji reactions on chat messages, 1:1 and groups, WhatsApp style. Channels already have their own
server-side reactions (`ChannelEndpoints`); this contract is only about end-to-end encrypted chats.

## Decisions

| Topic | Decision |
|---|---|
| Transport | An encrypted control message `type: "reaction"` through the normal pipeline (fan-out, sender copies, outbox, ack), exactly like `delete` and `edit`. The server relays an opaque blob and needs no change. |
| Cardinality | One reaction per person (identity) per message. A new emoji replaces the old one; the same emoji again removes it. |
| Removal | `emoji: ""`. Stored locally as a tombstone row (empty emoji) so an older reaction delivered late cannot bring it back. |
| Ordering | Last writer wins per (target, reactor) by the payload's `createdAt` (milliseconds). An equal timestamp is applied (same sender, same ordered ratchet: arrival order is sending order). |
| Who may react | Anyone in the conversation, to any message that is not a tombstone, a call log line or a device notice. The reactor is the AUTHENTICATED sender identity; nobody can react in someone else's name. |
| Target not (yet) known | The reaction is stored anyway (it may overtake its target from another sender) and shows once a message with that id exists in the SAME conversation. A reaction can never attach to a message in another conversation. |
| Business conversations | Refused in v1 (fail closed, like edit and delete). The archiver still accepts the type, see below. |
| Unread / chat order | A reaction never creates a message row, never bumps `unreadCount` and never changes `lastMessageAt`. |
| Own other devices | Get the reaction through the sender copy of the fan-out (`to` names the 1:1 conversation) and apply it under the own identity. |
| Sender | Applies its own reaction locally right away (optimistic). If the send fails, the previous state is restored, unless the user changed the reaction again in the meantime. |
| Deleting the target | Delete for everyone (tombstone) and delete for me remove the target's reactions. Wiping a removed companion and "reset for linking" remove all reactions. |
| Notification | A local notification "X reacted 👍 to: <preview>" when someone else reacts to MY message. Same rules as a message notification: off when notifications are off, the chat is open and focused, or the conversation is muted (`all`; `bots` mutes a bot's reactions). Previews off = the generic body. No removal notifications. |
| Picker | Quick bar 👍 ❤️ 😂 😮 😢 🙏 plus "+" for the full picker (`emoji_picker_flutter`, all six platforms). No double tap (it would delay every single tap on links and buttons). |
| Backup | Reactions are part of the encrypted backup (`reactions` array, additive; older backups simply have none). |

## Wire shape

Message payload (inside the E2E envelope, same outer keys as every message):

```json
{
  "v": 1,
  "id": "<new message id>",
  "type": "reaction",
  "body": "{\"targetId\":\"<target message id>\",\"emoji\":\"👍\"}",
  "groupId": null,
  "groupName": null,
  "to": "<peer identity id, 1:1 only>",
  "createdAt": "2026-11-07T10:15:00.123Z"
}
```

- `body` stays a STRING (every reader requires `body is String`); it holds JSON `{targetId, emoji}`.
- `targetId`: non-empty string, at most 64 characters.
- `emoji`: `""` (remove) or exactly ONE emoji grapheme: Extended_Pictographic base, optionally with
  skin tone, VS15/VS16, ZWJ sequence, tag sequence (subdivision flags), a regional indicator pair
  (flag) or a keycap (`1️⃣`); at most 32 UTF-16 code units. Text, digits, two emojis, or anything
  longer is invalid.
- Code: `calltype_core/lib/messaging/reaction.dart` (`ReactionPayload.encode/decode`,
  `isValidReactionEmoji`), shared by the app and the bots.
- Receiver: an invalid body or emoji is acked and dropped (never retried, never shown). Redelivery is
  recognised by the `control:<messageId>` marker in `backupState`, like `delete` and `edit`.

## Local storage (schema v8)

Table `message_reactions`: `message_id`, `reactor_id` (identity), `conversation_id`, `emoji`
(`""` = removed), `reacted_at` (ms since epoch, the payload `createdAt`). Primary key
(`message_id`, `reactor_id`). Migration v7 -> v8 creates the table; nothing else changes.

## Compatibility

| Receiver | Behaviour |
|---|---|
| Old app (before this change) | Throws "Unsupported message type" before storing anything, so the reaction stays queued on the server for that device until the 30-day TTL (same accepted cost as `edit`/`delete`). Nothing garbled is ever shown. |
| `calltype_bot` (old) | Acks and ignores every non-text type. |
| `calltype_bot` (new) | `onReaction(handler)`, see below. Without a handler: ack and ignore, as before. |
| `hermes_bridge` | Forwards owners' reactions to Hermes, see below. |
| `a2a_bridge` | Uses `calltype_bot` without `onReaction`: ack and ignore. |
| `jay_archiver` (new) | Archives a reaction like a text message (metadata only: kind `text`, size and SHA-256 of the body) so the K01 rule "no ack without a durable write" holds and no server change is needed. The app does not send reactions into business groups in v1, so this is defensive. |
| `jay_archiver` (old) | Would leave a reaction queued; unreachable in v1 because the app refuses business conversations. |
| Server | Unchanged. An offline device gets the usual generic "New message" push for a reaction (the server cannot tell a reaction from a message). |

## Bots

### `calltype_bot`

```dart
typedef BotReactionHandler = Future<void> Function(BotReaction reaction);
void onReaction(BotReactionHandler handler); // set before onMessage (which connects)

class BotReaction {
  String id;               // the reaction message id
  String targetId;         // reacted-to message
  String emoji;            // "" = removed
  bool get removed;
  String senderId;         // reactor identity
  String conversationId;   // peer identity (1:1) or group id
  bool isGroup; String? groupId;
  bool targetIsOwn;        // the target is a message this bot sent (remembered ones)
  String? targetText;      // first 200 characters of that message, when remembered
}
```

- The bot remembers the first 200 characters of the last 500 messages it sent (`sent-text:<id>` rows
  in its local `backupState`, updated by `edit`), so a reaction can say what it was about.
- 1:1: every valid reaction reaches the handler. Group: only reactions to the bot's OWN messages (the
  bot is not addressed otherwise, same rule as for messages).
- A reaction runs in the conversation's queue (after a turn in progress), without a typing
  indicator, and is acked after the handler (at most once, like messages). A handler error is logged
  and NOT answered with an apology.

### `hermes_bridge`

Only reactions of owners (`ALLOWED_HANDLES`) are forwarded; removals and reactions of other bots are
ignored. The agent sees:

```
[from CT-XXXX-XXXX] [reaction 👍 to your message: "<first 200 chars>"]
```

`REACTION_MODE` (env, default `silent`):

| Mode | Behaviour |
|---|---|
| `silent` | One Hermes turn per reaction with a note that no reply is shown. The answer is discarded, no progress message, approval requests in that turn are denied automatically. |
| `batch` | No turn. Reactions are kept in memory per conversation and prepended to the owner's next message (lost on restart). |
| `reply` | A normal turn; the answer is posted like a reply. |
| `off` | Ignored. |

## Limits

- No server push suppression: an offline recipient may see a generic "New message" push for a
  reaction (collapsed per conversation).
- Business conversations: no reactions in v1.
- Reactions are not shown in the chat list preview.
- "Who reacted" uses group member names / contact names; a former member shows as an id.
- iOS and macOS: `emoji_picker_flutter` adds a CocoaPod; not compiled on this Linux host, verified
  only by the next TestFlight / macOS CI build.
- Batch mode of the bridge keeps pending reactions in memory only.
