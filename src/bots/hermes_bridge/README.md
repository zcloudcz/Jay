# hermes_bridge

Makes a [Hermes Agent](https://github.com/NousResearch/hermes-agent) reachable
as a Jay contact. Thin glue: `calltype_bot` runtime ↔ Hermes' HTTP API server.
Messages stay end-to-end encrypted between the user and **this process**; the
plaintext is then handed to Hermes, so run both on the same trusted host.

## Security model — read this first

Hermes has a terminal and tools. Anyone who learns the bot's handle can send it
messages, therefore:

- `ALLOWED_HANDLES` is **fail-closed**: empty (or nothing resolvable) = the bot
  answers **nobody** and logs how to allow yourself.
- Messages from other senders are acknowledged and dropped **before decryption**:
  no Hermes call, no reply, no typing indicator.
- Handles are resolved to device ids **once at startup** — restart after changing
  the list, or after an allowed user reinstalls Jay (new device id).
- In a group, only allowed members can trigger the bot (by `@Hermes` / `@<handle>`),
  but the reply is visible to **every** member of that group.
- Other bots are answered **only in groups**, only where the group's owner turned
  on "Bot conversation" and one of your `ALLOWED_HANDLES` is a group **admin**; see
  "Two bots in one group". `PEER_BOT_HANDLES` can only narrow that further.
- The local `/send` endpoint is **off** unless `BRIDGE_SEND_KEY` is set, binds to
  127.0.0.1 only, and sends 1:1 messages only to `ALLOWED_HANDLES`. Channel posts
  go only to channels whose owner made the bot a publisher (the server checks).
- Keep Hermes' API on localhost. The bot's SQLite session DB is plaintext on disk
  (see `../calltype_bot/README.md`), so the host must be trusted.

## Configuration (environment only)

| Variable | Required | Meaning |
| --- | --- | --- |
| `CALLTYPE_API_URL` | yes | CallType API base URL |
| `BOT_STORE_KEY` | yes | base64 of exactly 32 bytes (`openssl rand -base64 32`); encrypts the identity store |
| `BOT_STORE_PATH` | yes (image default `/data/bot.store`) | identity store; `<path>.sqlite` is created next to it |
| `BOT_DISPLAY_NAME` | no, default `Hermes` | name users can `@mention` in groups |
| `HERMES_URL` | no, default `http://127.0.0.1:8642` | Hermes API server |
| `HERMES_API_KEY` | yes | Hermes' `API_SERVER_KEY` |
| `HERMES_TIMEOUT_SECONDS` | no, default `300` | per-request timeout (agent turns with tools are slow) |
| `ALLOWED_HANDLES` | effectively yes | comma-separated `CT-XXXX-XXXX` handles allowed to talk to Hermes |
| `PEER_BOT_HANDLES` | no | comma-separated handles of other bots; if set, ONLY these may talk to this one (narrows the group setting, never widens it; set but unresolvable = no bot) |
| `PEER_MAX_TURNS_CAP` | no, default `50` | operator ceiling for a bot-only exchange; a group's "max messages" above it is cut down to it |
| `BRIDGE_SEND_KEY` | no | enables `POST http://127.0.0.1:$BRIDGE_PORT/send`; the Bearer key callers must send. Unset = endpoint off |
| `BRIDGE_PORT` | no, default `8650` | port of the local send endpoint (loopback only) |
| `HERMES_STREAM` | no, default `true` | stream turns (`/api/sessions/{id}/chat/stream`, SSE): progress and approval buttons. `false` = plain `/chat`. A Hermes without the stream route is detected (404 after the session exists) and `/chat` is used from then on |
| `PROGRESS_AFTER_SECONDS` | no, default `8` | post "Working on it..." when no answer came after this long; `0` = never |
| `PROGRESS_EDIT_SECONDS` | no, default `5` | min seconds between progress edits (current tool) |
| `PROGRESS_MAX_EDITS` | no, default `30` | progress edits per turn; then it stays until the answer replaces it |
| `BOT_COMMANDS` | no | `cmd:description;cmd2:description` published as the bot's "/" menu at start (a bad entry stops the start; an old server without the endpoint is logged and ignored) |
| `PEER_REPLY_LIMIT`, `PEER_REPLY_WINDOW_MINUTES` | obsolete | ignored with a log line; limits now come from the group setting |

## Run

```bash
# once, from the repo root: generate the core's drift code
cd src/client/calltype_core && dart pub get && dart run build_runner build --delete-conflicting-outputs

cd ../../bots/hermes_bridge && dart pub get
export CALLTYPE_API_URL=https://<api-host>
export BOT_STORE_KEY=$(openssl rand -base64 32)   # keep it! losing it = new bot identity
export BOT_STORE_PATH=$HOME/.hermes-bridge/bot.store
export HERMES_API_KEY=<API_SERVER_KEY of your Hermes>
export ALLOWED_HANDLES=CT-XXXX-XXXX               # your own handle: Jay -> Settings -> Identity
dart run bin/hermes_bridge.dart
```

The first start prints the bot's handle and a `ct://…` invite — add it in Jay
(contacts → enter handle or paste the invite).

Standalone binary: `dart build cli -o build/out` → `build/out/bundle/bin/hermes_bridge`
plus `bundle/lib/` (bundled SQLite). `dart compile exe` does **not** work:
`package:sqlite3` delivers its native library through a build hook that only
`dart build` runs.

Docker (context is `src/`, because of the path dependencies):

```bash
docker build -f src/bots/hermes_bridge/Dockerfile -t hermes-bridge src
docker run -d --restart unless-stopped --network host -v hermes-bridge:/data \
  -e CALLTYPE_API_URL -e BOT_STORE_KEY -e HERMES_API_KEY -e ALLOWED_HANDLES -e BRIDGE_SEND_KEY hermes-bridge
```

Docker image (built by `.github/workflows/hermes-bridge-image.yml`):
`docker run ... ghcr.io/zcloudcz/jay-hermes-bridge:latest` (same flags as above).

## Two bots in one group

Run two bridges, put both bots and yourself in one Jay group (you as **admin**),
and in the group detail turn on "Bot conversation" (All bots, or Selected bots
with **both** bots ticked). The group decides; nothing has to be configured in
the bridges. A bot answers another bot in group G only if all hold:

1. G's bot talk is `all`, or `selected` and both the sender and this bot are listed.
   A server without the setting counts as `off`.
2. One of this bridge's `ALLOWED_HANDLES` is an `admin` member of G.
3. The current exchange (bot messages since the last human mention) is below
   min(G's max messages, `PEER_MAX_TURNS_CAP`).
4. After an exchange hit its limit, a new one starts only after G's pause.

- At the limit the bot posts one notice (`Bot limit reached, waiting for a human.`)
  and stays silent. A message from an `ALLOWED_HANDLES` member that mentions the
  bot resets counter and pause (unmentioned group messages never reach the bot).
  Counters are in memory and reset on restart.
- Bots address each other with `@<handle>`. Bot-to-bot 1:1 chats are always ignored.
- Every text passed to Hermes is prefixed `[from CT-XXXX-XXXX]: ` (human) or
  `[from CT-XXXX-XXXX (bot)]: ` (peer).
- In a group all replies, including bot-to-bot ones, are visible to every member.
- Group settings are cached and re-read on the server's group-changed hint (and at
  the latest after 5 minutes).
- Add to Hermes' instructions: "To ask the other agent, mention it as @<its handle>."

## Replies, progress, approvals

- **Addressing in groups:** `@<handle>`, a structured mention from the app, or a
  reply to one of the bot's messages. Group answers quote the message they
  answer.
- **Quote context:** a message that replies to something reaches Hermes as
  `[Replying to: "<preview>"]` + newline + text; a pressed button that is not an
  approval as `[Button: <label>]`.
- **Progress:** after `PROGRESS_AFTER_SECONDS` without an answer the bot posts
  "Working on it...", edits it (throttled, capped) with the current tool, and
  finally edits it into the answer (longer answers: the rest follows as
  replies). A failed turn turns the progress message into the apology.
- **Approvals:** Hermes' `approval.request` becomes a message with the command
  and the buttons "Approve once" / "Approve for session" / "Deny" (only the
  choices Hermes offers; never "always"). Only an `ALLOWED_HANDLES` owner may
  press; anyone else that can reach the bot (an admitted peer bot) gets "Only
  the bot owner can approve." A press posts `POST /v1/runs/{run_id}/approval
  {"choice", "request_id"}` and edits the message to the outcome, without
  buttons. Requests still open when the turn ends lose their buttons
  ("No longer pending."). Presses are handled outside the conversation queue,
  because the turn that asked is blocked waiting for them.
- Button ids are `approve:<token>:<choice>` with a 12-hex local token, not the
  Hermes ids: run id (36) + request id (32) do not fit the 64-character button
  id limit, and only requests this bridge issued (and still waits for) can be
  answered.

## Starting a message: local `/send`

With `BRIDGE_SEND_KEY` set, Hermes tools and cron jobs can post into Jay:

```bash
curl -sS -X POST http://127.0.0.1:8650/send \
  -H "Authorization: Bearer $BRIDGE_SEND_KEY" -H 'Content-Type: application/json' \
  -d '{"to": "<group id, CT-XXXX-XXXX or channel:CH-XXXX-XXXX>", "text": "deploy 28f5070 done"}'
```

| Status | Meaning |
| --- | --- |
| 202 | sent (long text is split into several messages) |
| 400 | body is not `{"to": string, "text": string}` (or over 256 KiB); `bad_target`: `channel:` without a `CH-XXXX-XXXX` handle or channel id, or an unknown channel; `text_too_long`: a channel post over 4096 characters |
| 401 | missing or wrong key |
| 403 | target not allowed: a handle not in `ALLOWED_HANDLES`, a group the bot is not in, the group's bot exchange is used up (a post counts as one bot turn, rules 3 and 4), or a channel where the bot is not owner/admin/publisher; `{"error": "channel_suspended"}` when moderation suspended the channel |
| 404 / 405 | other path / method |
| 429 | `bot_post_limit`: the bot's daily post limit in that channel is used up (server `Channels:MaxBotPostsPerDay`, default 20 per 24 h); do not retry today |
| 502 | allowed, but the hub (or the API, for a channel) did not take it (retry later) |

Text only; reference artifacts by commit or path.

### Posting to a channel (newsletter)

`"to": "channel:CH-XXXX-XXXX"` (or `"channel:<channel id>"`) publishes ONE public
text post as the bot, labelled BOT in the app. It is not split (every post counts
against the daily limit) and it is not a group bot turn. The server alone decides
whether the bot may post: role, suspension and the daily limit. Every attempt is
logged (`/send: posted <postId> to channel ...` or the refusal with its code).

**Make the bot a publisher** (channel owner, in the Jay app): open the channel
profile -> **Admins** -> **Add by handle** -> type the bot's `CT-XXXX-XXXX` handle
(printed by the bridge on first start) -> role **Publisher**. A publisher can post
and delete its own posts only; it cannot edit the channel, manage admins or touch
other posts. Remove it there to stop the bot at once.

**Recipe: a weekly newsletter from a Hermes cron job.** Keep the key out of the
prompt: a small script reads the text on stdin and posts it.

```bash
#!/usr/bin/env bash
# ~/.hermes/scripts/jay-channel-post.sh  (chmod 700; key file chmod 600)
set -euo pipefail
key=$(cat ~/.config/jay/bridge-send-key)
jq -Rs '{to: "channel:CH-XXXX-XXXX", text: .}' |
  curl -sS -o /dev/stderr -w '%{http_code}\n' -X POST http://127.0.0.1:8650/send \
    -H "Authorization: Bearer $key" -H 'Content-Type: application/json' --data-binary @-
```

```bash
hermes cron create '0 8 * * 1' --name jay-newsletter --deliver local \
  "Write this week's newsletter for our Jay channel: plain text, at most 4000
   characters, no secrets or private data. Then pipe exactly that text into
   ~/.hermes/scripts/jay-channel-post.sh. It prints the HTTP status: 202 = posted;
   429 = daily bot limit, stop; 403 = not a publisher or channel suspended, stop
   and report; 502 = try once more in a few minutes."
```

A job that only forwards existing text (no LLM) can run the same script with
`--script ... --no-agent`. Follow the channel rules (K1..K10, `docs/legal/`): bot
posts are moderated like any other.

## Hermes contract: verified vs assumed

Everything Hermes-specific lives in `HermesClient` (`lib/hermes_bridge.dart`)
and `lib/src/hermes_events.dart`.

**Verified by reading `gateway/platforms/api_server.py` (main branch, 2026-09-17):**

- Routes exist: `POST /api/sessions`, `POST /api/sessions/{session_id}/chat`
  (also `/v1/chat/completions`, `/v1/responses`, … — not used).
- Auth: `Authorization: Bearer <API_SERVER_KEY>`; defaults `127.0.0.1:8642`
  (`API_SERVER_HOST` / `API_SERVER_PORT`).
- `POST /api/sessions` takes `id` (or `session_id`), max 256 chars, no control
  characters, must be path-safe; returns **201**, or **409 `session_exists`**.
- Session chat takes `message` (or `input`), loads the stored history of that
  session server-side, runs one synchronous turn and returns
  `{"object":"hermes.session.chat.completion","session_id":…,"message":{"role":"assistant","content":…}}`.
- An unknown session answers **404 `session_not_found`** (`_get_existing_session_or_404`) —
  the client then creates it and repeats the chat.

**Why not `/v1/chat/completions`:** it is OpenAI-style, i.e. the client resends
the history. The session API keeps memory in Hermes, keyed by our
`calltype-<conversationId>` — the bridge stays stateless.

**Streaming and approvals (read in `api_server.py` / `api_server_runs.py`, 2026-11-05):**

- `POST /api/sessions/{id}/chat/stream` answers SSE frames `event: <name>` +
  `data: <json>`: `run.started`, `message.started`, `assistant.delta
  {message_id, delta}`, `tool.started` / `tool.completed` / `tool.failed
  {tool_name, preview, args}`, `tool.progress` (thinking, ignored),
  `approval.request {run_id, request_id, command, description, choices, ...}`,
  **`assistant.completed {content}`** (the final answer), `run.completed` /
  `run.failed`, `error {message}`, `done {}`; `: keepalive` comments in between.
- `POST /v1/runs/{run_id}/approval {"choice": once|session|always|deny,
  "request_id"}` -> 200, or 409 `approval_not_pending` / `approval_not_active`.
- While streaming, `HERMES_TIMEOUT_SECONDS` is the longest silence allowed
  (keepalives count), not the length of the turn.

**Assumed (not verified against a running Hermes):**

- `calltype-<uuid>` passes Hermes' `_is_path_unsafe` check;
- Hermes persists each turn so the next one sees it;
- overload is signalled by 429/5xx (both retried once);
- how the API server is switched on in your Hermes install — see Hermes' docs.

Failure policy: connection errors and 5xx/429 are retried **once**; a **timeout
is not retried** — the turn may still be running tools and a resend would run it
twice. The user gets a short apology instead. Replies longer than 4000
characters are split into several messages (the hub's own limit is ~768 KiB per
envelope; 4000 is for readability).

## Not verified

No end-to-end run against the hosted CallType API or a real Hermes has been
done, and the Docker image was not built (no Docker on the dev machine). Tests
(`dart test`) cover the Hermes client against a loopback fake and the allowlist
with real crypto on both sides.
