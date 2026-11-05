# Contract: agent messaging (feat/agent-messaging)

Every layer codes against this file. Do not rename anything without updating it. Design: `2026-11-05-agent-messaging-design.md`.

## 1. Wire payload (inside the E2E envelope, `v: 1`, all keys additive)

Existing keys stay: `v, id, body, type, groupId, groupName, createdAt, to, replyTo {id, senderId, preview}, forwarded`.

| Key | On type | Shape | Receiver rule |
|---|---|---|---|
| `mentions` | `text` | `["<identity id>", ...]` lower-case GUID strings, max 50 | Ignore if not a list of strings; extra entries ignored. |
| `actions` | `text`, `edit` | `[{"id": "<1..64 of [A-Za-z0-9_.:-]>", "label": "<1..40 chars>"}]`, max 8 | Drop invalid entries, keep max 8. App renders only when the SENDER is a bot. On `edit`: key present = replace buttons (empty list = remove), key absent = keep. |
| `action` | `text` | `{"messageId": "<id of the bot message>", "id": "<action id>"}` | Body = the label (readable for old bots). The message also carries `replyTo` of that bot message. |
| `editOf` | `edit` | `"<target message id>"` | Required for `edit`. |

`type: "edit"`: `body` = the full new text. Apply only if the target exists, is `type: text`, is not deleted, and the
target's sender identity == the edit's authenticated sender identity; and only if the edit's `createdAt` is newer than
the stored `editedAt` (out-of-order edits lose). Otherwise drop. Either way acknowledge and record `control:<id>` in
`backupState` like `delete`. An edit never creates a message and never changes `unreadCount`.

Bots: a reply in a GROUP sets `replyTo` = `{id: <incoming id>, senderId: <incoming sender identity>, preview: <first 100
chars of the incoming body>}`. 1:1 replies do not quote.

## 2. Shared helpers in calltype_core (`lib/messaging/agent_payload.dart`)

```dart
class MessageButton { final String id; final String label; Map<String, dynamic> toJson(); }
class ActionRef { final String messageId; final String id; Map<String, dynamic> toJson(); }
List<String> parseMentions(Object? raw);          // lower-cased, deduped, max 50, never throws
List<MessageButton> parseActions(Object? raw);     // validated, max 8, never throws
ActionRef? parseActionRef(Object? raw);            // null if invalid
String? parseEditOf(Object? raw);
const maxActions = 8, maxMentions = 50, maxActionLabel = 40, maxActionId = 64;
final actionIdPattern = RegExp(r'^[A-Za-z0-9_.:-]{1,64}$');
```

## 3. Client DB (calltype_core `tables.dart`, schemaVersion 6)

`messages` gains: `editedAt` (DateTime, nullable), `actionsJson` (text, nullable; JSON list of `MessageButton`).
Migration `from < 6`: add both columns. Backup export/import carries both (like `replyToId`).

## 4. Server: bot commands

Device gains `BotCommandsJson` (text, nullable). Migration `AddBotCommands` (`--context AppDbContext`), additive.

- `PUT /devices/{id}/bot-commands` (auth, rate limit "api"). Caller must be device `{id}` (else 403) and `IsBot` (else 403
  problem `error: not_a_bot`). Body `{"commands": [{"command": "help", "description": "Show help"}]}`.
  `command` ^[a-z0-9_]{1,32}$, unique; `description` 1..100 chars after trim; max 50 entries; empty list = clear.
  400 problem `error: invalid_bot_commands`. 200 -> `{"commands": [...]}` as stored.
- `GET /devices/{id}/bot-commands` (auth, any device, rate limit "api"). 200 -> `{"commands": [...]}` (empty for no list
  or a non-bot). 404 for an unknown device.
- No hub hint; clients cache per bot for 10 minutes.

calltype_core `ApiClient`: `Future<List<BotCommand>> getBotCommands(String deviceId)`,
`Future<List<BotCommand>> setBotCommands(String deviceId, List<BotCommand> commands)`;
`class BotCommand {String command; String description; toJson/fromJson}` in `lib/network/bot_dtos.dart`.

## 5. Bot runtime (calltype_bot)

```dart
class BotReplyRef { final String id; final String senderId; final String preview; }
class BotMessage {
  ...existing...
  final BotReplyRef? replyTo;
  bool get repliesToBot;        // replyTo?.senderId == bot deviceId (case-insensitive)
  final ActionRef? action;      // a button press, if any
  bool get mentionsBot;         // structured mentions contain the bot OR text match (existing function)
  bool get addressed;           // mentionsBot || repliesToBot
  Future<BotSentMessage> reply(String text, {List<MessageButton> actions = const []});
}
class BotSentMessage {
  final String id; final String conversationId; final String? groupId;
  Future<void> edit(String text, {List<MessageButton>? actions}); // null = keep buttons, [] = remove
}
CallTypeBot.send({required String to, required String text, List<MessageButton> actions = const []}) -> Future<BotSentMessage>
CallTypeBot.setCommands(List<BotCommand> commands) -> Future<void>
CallTypeBot.deepLink({String? start}) -> String   // calltype://bot/<HANDLE>[?start=<payload>]
CallTypeBot.onAction(BotMessageHandler handler)   // optional
```

- Group gate: handle when `addressed` (was: text mention only). 1:1 unchanged.
- A message whose `action.messageId` is a message THIS bot sent (runtime keeps the ids of its sent messages with
  buttons, in memory + `backupState` key `sent-actions:<id>`) goes to the `onAction` handler when one is set, OUTSIDE the
  per-conversation queue (WHY: the conversation's handler may be blocked waiting for exactly this button, e.g. an
  approval). Without `onAction` it goes to the normal handler.
- `type: edit` from others: ack and ignore.
- Deep-link payload: `start` 1..64 of [A-Za-z0-9_-].

## 6. Hermes bridge env (new, all optional)

| Env | Default | Meaning |
|---|---|---|
| `HERMES_STREAM` | `true` | use `POST /api/sessions/{id}/chat/stream` (SSE: `assistant.delta`, `tool.started`, `tool.completed`, `tool.failed`, `approval.request`, `error`, `done`); 404 = fall back to `/chat` |
| `PROGRESS_AFTER_SECONDS` | `8` | send a progress message when no answer yet; 0 = never |
| `PROGRESS_EDIT_SECONDS` | `5` | min interval between edits |
| `PROGRESS_MAX_EDITS` | `30` | then stop editing until the final answer |
| `BOT_COMMANDS` | empty | `cmd:description;cmd2:description` published via `setCommands` at start |

Approvals: `approval.request` -> message with buttons `approve:<runId>:<requestId>:once` ("Approve once"),
`...:session` ("Approve for session"), `...:deny` ("Deny") and the command preview. Only an owner (`ALLOWED_HANDLES`
identity) may press; others get "Only the bot owner can approve." Press -> `POST /v1/runs/{runId}/approval`
`{"choice": "once"|"session"|"deny", "request_id": "<requestId>"}`, then the button message is edited to the result
without buttons. Quote context: a message with `replyTo` is sent to Hermes as `[Replying to: "<preview>"]\n<text>`;
a button press that is not an approval as `[Button: <label>]`.

## 7. A2A bridge (`src/bots/a2a_bridge`)

Env: `CALLTYPE_API_URL`, `BOT_STORE_KEY`, `BOT_STORE_PATH` (default `/data/bot.store`), `ALLOWED_HANDLES` (required,
fail-closed), `A2A_AGENT_URL` (required; card at `<url>/.well-known/agent-card.json`, fallback `/.well-known/agent.json`),
`A2A_TOKEN` (optional bearer), `BOT_DISPLAY_NAME` (default: card `name`), `A2A_TIMEOUT_SECONDS` (300),
`A2A_POLL_SECONDS` (3), `A2A_STATE_PATH` (default `<BOT_STORE_PATH>.a2a.json`: conversation -> contextId / open taskId).
Protocol: JSON-RPC 2.0 to the card's JSON-RPC endpoint; method `SendMessage` (v1.0, role `ROLE_USER`, parts `[{"text"}]`),
on `-32601` fall back to `message/send` (v0.3, role `user`, parts `[{"kind":"text","text"}]`). Result Message -> reply;
Task -> by state: completed (artifacts + status message text) -> reply; input-required -> reply and remember `taskId`
for the next message of that conversation; working/submitted -> progress message + poll `GetTask` (`tasks/get`) every
`A2A_POLL_SECONDS` until terminal or timeout, editing progress; failed/rejected/canceled -> short error. Card skills are
published as bot commands (id normalized to `^[a-z0-9_]{1,32}$`).
Docker image like hermes_bridge (`ghcr.io/zcloudcz/jay-a2a-bridge`), workflow `a2a-bridge-image.yml`.

## 8. App

- Mentions: picking a candidate remembers its identity id; on send `mentions` = ids whose `@token` is still in the text.
- Buttons under received bot messages (`actionsJson`); tap -> send label with `replyTo` + `action`.
- Edit: receive (section 1), "edited" label, own text messages get an "Edit" action (sends `type: edit`).
- "/" at the start of the composer in a chat with a bot (1:1 contact `isBot`, or group with bot members) suggests
  `GET /devices/{botId}/bot-commands`; in groups inserts `/cmd@HANDLE `.
- Deep link `calltype://bot/<HANDLE>?start=<payload>`: add/open the contact by handle (existing add-contact flow with
  confirmation), open the chat, pre-fill `/start <payload>`. Never auto-send.
- All strings through l10n (every existing locale).
