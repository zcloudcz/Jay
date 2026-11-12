# a2a_bridge

Makes any [A2A](https://a2a-protocol.org) agent (A2A v1.0, with automatic
fallback to v0.3) reachable as a Jay contact: Copilot Studio, Azure AI Foundry,
Google ADK, LangGraph, another Hermes, anything that serves an Agent Card and
JSON-RPC. Thin glue: `calltype_bot` runtime <-> the agent's JSON-RPC endpoint.
Messages stay end-to-end encrypted between the user and **this process**; the
plaintext is then sent to the agent, so the path to the agent must be trusted
(HTTPS or the same host).

## Security model, read this first

- `ALLOWED_HANDLES` is **fail-closed and required**: empty, malformed, or none
  of the handles known to the server = the bridge **refuses to start**
  (exit 78). Only those owners can talk to the agent.
- Messages from anyone else are acknowledged and dropped **before decryption**:
  no agent call, no reply, no typing indicator. Other bots are never answered
  (no bot-to-bot talk through this bridge).
- In a group, an owner addresses the bot by `@mention` or by replying to it; the
  agent's answer is visible to **every** member of that group. The agent sees
  `[from CT-XXXX-XXXX]` in front of group messages so it knows who is speaking.
- `A2A_TOKEN` comes from the environment only and is sent as
  `Authorization: Bearer <token>` **only to the origin of `A2A_AGENT_URL`** (or
  of `A2A_ENDPOINT_URL`). A card that names an endpoint on another origin makes
  the bridge refuse to start instead of handing the token to that host.
- Agent replies are relayed as **text only**: file parts become a
  `[file: name] <url>` note, inline bytes are never decoded, data parts become
  JSON text. Responses over 4 MiB are refused.
- `A2A_STATE_PATH` holds only conversation ids -> A2A `contextId` / open
  `taskId`, no message content. Delete it to make the agent forget all chats.
- The bot's SQLite session DB is plaintext on disk (see
  `../calltype_bot/README.md`), so the host must be trusted.

## Configuration (environment only)

| Variable | Required | Default | Meaning |
| --- | --- | --- | --- |
| `CALLTYPE_API_URL` | yes | | CallType (Jay) API base URL |
| `BOT_STORE_KEY` | yes | | base64 of exactly 32 bytes (`openssl rand -base64 32`); encrypts the identity store |
| `BOT_STORE_PATH` | no | `/data/bot.store` | identity store; `<path>.sqlite` is created next to it |
| `ALLOWED_HANDLES` | yes | | comma-separated `CT-XXXX-XXXX` handles allowed to talk to the agent |
| `A2A_AGENT_URL` | yes | | agent base URL; card at `<url>/.well-known/agent-card.json`, fallback `<url>/.well-known/agent.json`. A URL ending in `.json` is taken as the card itself |
| `A2A_TOKEN` | no | | bearer token for the agent |
| `A2A_ENDPOINT_URL` | no | card's JSON-RPC interface | explicit JSON-RPC endpoint, for agents behind a proxy whose card advertises another origin |
| `BOT_DISPLAY_NAME` | no | card `name` | name users can `@mention` in groups |
| `A2A_TIMEOUT_SECONDS` | no | `300` | max time per message (send + polling) |
| `A2A_POLL_SECONDS` | no | `3` | `GetTask` polling interval while a task is working |
| `ACK_REACTIONS` | no | `on` | `on`: 👀 on every owner message before it goes to the agent, then ✅ answered, 👍 nothing to post, ❌ an error text (timeout, unreachable, failed/rejected/canceled task); `off`: none |
| `A2A_STATE_PATH` | no | `<BOT_STORE_PATH>.a2a.json` | conversation -> `contextId` / open `taskId` |

## What it does

- **Start:** reads the Agent Card, picks its JSON-RPC interface
  (`supportedInterfaces[]` with `protocolBinding: JSONRPC`, v0.3 `url` /
  `additionalInterfaces`), registers the bot (display name = card name) and
  publishes `/reset` plus one command per card skill (skill id normalised to
  `^[a-z0-9_]{1,32}$`, e.g. `toolset.web` -> `/toolset_web`).
- **Message:** `SendMessage` (v1.0: role `ROLE_USER`, parts `[{"text"}]`,
  header `A2A-Version: 1.0`). On JSON-RPC `-32601` it retries once with
  `message/send` (v0.3: role `user`, parts `[{"kind":"text","text"}]`) and keeps
  using v0.3. Every chat keeps its own A2A `contextId`, so the agent remembers
  the conversation, also across restarts.
- **Result:** a Message is the reply. A Task by state: `completed` -> status
  note + artifacts; `input-required` -> the question, and the next message of
  that chat continues the same `taskId`; `submitted` / `working` -> a
  "Working on it..." message, `GetTask` polling every `A2A_POLL_SECONDS`, the
  message is edited when the agent's status text changes (max 30 edits) and
  finally becomes the answer; `failed` / `rejected` / `canceled` /
  `auth-required` -> a short error; no result in `A2A_TIMEOUT_SECONDS` -> a
  timeout notice.
- **Commands:** `/reset` forgets the chat's context (new agent conversation).
  `/<skill> text` is sent as `[Skill: <skill id>] text`.
- Long answers are split into 4000-character messages.
- **Acknowledgement reactions** (`ACK_REACTIONS=on`, spec
  `2026-11-11-bot-ack-reactions`): 👀 when a message is accepted, replaced
  by ✅ / 👍 / ❌ when the turn ends. No 👀 = the bridge is down. The agent
  cannot choose the emoji (no `[react:EMOJI]` directive here). Reactions,
  also other bots', are acked and ignored and never start a turn.

## Run

```bash
# once, from the repo root: generate the core's drift code
cd src/client/calltype_core && dart pub get && dart run build_runner build --delete-conflicting-outputs

cd ../../bots/a2a_bridge && dart pub get
export CALLTYPE_API_URL=https://<api-host>
export BOT_STORE_KEY=$(openssl rand -base64 32)   # keep it! losing it = new bot identity
export BOT_STORE_PATH=$HOME/.a2a-bridge/bot.store
export ALLOWED_HANDLES=CT-XXXX-XXXX               # your own handle: Jay -> Settings -> Identity
export A2A_AGENT_URL=http://127.0.0.1:9900
export A2A_TOKEN=<agent bearer token>             # if the agent wants one
dart run bin/a2a_bridge.dart
```

The first start prints the bot's handle and a `ct://...` invite; add it in Jay
(contacts -> enter handle or paste the invite).

Docker (context is `src/`, because of the path dependencies):

```bash
docker build -f src/bots/a2a_bridge/Dockerfile -t a2a-bridge src
docker run -d --restart unless-stopped --network host -v a2a-bridge:/data \
  -e CALLTYPE_API_URL -e BOT_STORE_KEY -e ALLOWED_HANDLES \
  -e A2A_AGENT_URL -e A2A_TOKEN a2a-bridge
```

Docker image (built by `.github/workflows/a2a-bridge-image.yml`):
`docker run ... ghcr.io/zcloudcz/jay-a2a-bridge:latest` (same flags as above).

## Talking to Hermes' A2A plugin

Hermes (`plugins/platforms/a2a`) serves a v1.0 card and accepts both
`SendMessage`/`GetTask` and the v0.3 names; `SendMessage` blocks until the
answer, so the bridge normally gets a finished task (the typing indicator runs
meanwhile). Set on the Hermes side:

- `A2A_BEARER_TOKEN` (or a per-peer entry in `A2A_PEER_TOKENS`) = this bridge's
  `A2A_TOKEN`, and, for a non-loopback bind, `A2A_TRUSTED_PEERS`.
- `A2A_MAX_PINGPONG_TURNS=20`: Hermes rejects a context after that many turns
  per hour (default **5**). The bridge reuses one context per chat, so with the
  default the sixth message within an hour is rejected; the user then sees the
  reason and can send `/reset`.
- `A2A_REPLY_TIMEOUT` should not exceed this bridge's `A2A_TIMEOUT_SECONDS`.

## Tests

```bash
dart test   # fake A2A server on loopback; no Jay server needed
```

The runtime glue (`lib/src/jay_glue.dart`) is the only file that imports
`calltype_bot`; everything else is runtime-free and covered by the tests.
