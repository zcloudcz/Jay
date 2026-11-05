# Agent messaging: replies, mentions, commands, buttons, edits, A2A bridge (design)

Status: approved by Martin 2026-11-05 ("F1-F3 ok", "naplanuj to a rovnou implementuj"), prepared by Hermes Dev.
Branch: `feat/agent-messaging`. Exact names: `2026-11-05-agent-messaging-contract.md`.

## Why

Jay already carries humans and bots in one E2E conversation (Hermes bridge, bot conversations). Compared with Telegram,
Matrix, XMPP and Slack the bot experience lacks: addressing a bot by replying to it, reliable mentions, discoverable
commands, buttons (approvals!), progress instead of minutes of silence, and a way to put a non-Hermes agent (Copilot
Studio, Azure AI Foundry, Google ADK, any A2A v1.0 agent) into Jay. Research: Jarvis research note 2026-11-05.

## Decisions

| # | Decision | Precedent |
|---|---|---|
| D1 | Replying to a bot's message addresses the bot in a group (no `@` needed). Bots quote the message they answer in groups. | Telegram reply_to_message, XMPP XEP-0461, Matrix m.in_reply_to |
| D2 | Messages carry structured `mentions` (identity ids); the text `@handle` match stays as fallback for old clients. | Matrix m.mentions (MSC3952) |
| D3 | Anti-loop in the envelope: NOT done. Bot conversations (group `botTalk`, receiver-side limits) already cover it. | |
| D4 | Deep link `calltype://bot/<HANDLE>?start=<payload>` opens/adds the bot and PRE-FILLS `/start <payload>`; the user presses send (no auto-send). | Telegram /start payload |
| D5 | Bot commands are public bot metadata on the server (like the display name), set by the bot, read by clients; "/" in the composer suggests them. In groups the app inserts `/cmd@HANDLE`. | Telegram setMyCommands, XMPP XEP-0050 |
| D6 | Buttons: a bot message may carry up to 8 `actions`; the app renders them only for messages from bot senders. A tap sends a normal text message (body = label) that replies to the bot message and carries `action`. Old bots see plain text. | Telegram inline keyboard, XEP-0004 |
| D7 | Edits: new control type `edit` (like `delete`): only the original sender, only text messages, newest `createdAt` wins. Users can edit their own text messages too. Bots use it for progress ("working... tool X") and to remove buttons after a choice. | Telegram editMessageText, Matrix m.replace |
| D8 | Hermes bridge: streams Hermes (`/api/sessions/{id}/chat/stream`), shows a progress message after a few seconds, turns it into the answer at the end; Hermes dangerous-command approvals become buttons, only the bot's owners (`ALLOWED_HANDLES`) may press them. | |
| D9 | New `a2a_bridge` bot: any A2A agent becomes a Jay contact; same allowlist model as the Hermes bridge (fail-closed). No server change. | A2A v1.0 (Linux Foundation) |
| D10 | Out of scope: signed agent cards/verified badge (F4), A2A over Jay transport (F5), threads, MLS. | |

## Compatibility

- All new payload keys are additive on `type: text`; old clients ignore them (they show the text, no buttons).
- `type: edit` is new: an old client throws on an unknown type, so the edit stays queued for it until the server TTL
  (same accepted trade-off as `delete`). Bots therefore throttle progress edits (min interval, max count).
- Bot commands: new endpoints + one additive migration (`AddBotCommands`). Old app = no "/" menu, nothing breaks.

## Security

- Buttons from humans are not rendered (phishing). A button tap is just a message; the BOT decides what it may do.
  The Hermes bridge accepts an approval only from an owner (`ALLOWED_HANDLES`), only for a pending request it issued.
- Edits: receiver checks that the edit's authenticated sender identity equals the target's sender; never edits other
  people's messages; deleted messages stay deleted.
- Mentions are a hint about addressing, not authority: allowlists and bot-talk rules stay unchanged.
- Bot commands are public plaintext metadata (like display name); only a bot device may set its own list.
- A2A bridge: `ALLOWED_HANDLES` fail-closed; agent token only from env; agent replies are text only.

## Tests

Server: endpoint auth (self only, bot only), validation, GET for others. Core: payload helpers. Runtime: reply-to
addressing, mentions, action routing outside the conversation queue, edit/actions sending, commands. Bridge: streaming,
progress/edit throttle, approval buttons (owner only), quote context. App: mention ids, buttons render/tap, edit
receive/send, "/" menu, deep link parse. A2A bridge: fake A2A server (message reply, task completed, input-required,
working -> poll, failed, v0.3 fallback). Live E2E against docker-compose, plus the A2A bridge against a real Hermes
A2A endpoint.
