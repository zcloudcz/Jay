# llm_bridge

A Jay contact answered by a language model. A thin layer around the Anthropic
Messages API, the OpenAI Chat Completions API (and every compatible server),
or the owner's own signed-in Claude Code / Codex CLI. No tools, no agent
framework: a chat with memory. The bot is an ordinary Jay device; its keys are
created on, and never leave, the machine that runs it.

The easy way to run it is the "New bot" wizard in the Jay app (Settings ->
Bots), which prints one command for `infra/bots/jay-new-bot.sh` (Linux, macOS,
Docker) or `jay-new-bot.ps1` (Windows). This README is the reference behind it.
Contract: `docs/superpowers/specs/2026-11-09-bot-factory.md`.

## Security model, read this first

- `ALLOWED_HANDLES` is **fail-closed and required**: empty, malformed, or none
  of the handles known to the server = the bridge **refuses to start**
  (exit 78). Every answer is paid from the owner's key or plan.
- Who can reach the bot (spec `2026-11-09-bot-access`):
  1. **Owners**, 1:1 and in groups.
  2. **Members of a group that has an owner in it** (`GROUP_REPLIES=members`,
     the default for API keys) when they `@mention` the bot or reply to it.
     Their questions are paid from the **owner's** key. In a group without
     an owner the bot stays silent. The CLI (subscription) providers default
     to `GROUP_REPLIES=owners`, see "Subscription providers" below.
  3. **Other bots**, only in groups, only where the group's "Bot
     conversation" setting allows it and an owner is a member, up to the
     group's turn limit (capped by `PEER_MAX_TURNS_CAP`). Never 1:1.
- Everyone else is acknowledged and dropped **before decryption**: no model
  call, no reply, no typing indicator. At start the bot also publishes a
  server-side inbound policy (owners = the resolved `ALLOWED_HANDLES`), so
  the server does not even store 1:1 messages from strangers or messages of
  groups without an owner (`BOT_INBOUND=open` turns that off).
- In a group the answer quotes the asker and is visible to **every** member.
  The model sees `[from CT-XXXX-XXXX]` (or `[from Name (bot)]`) in front of
  group messages; a group has ONE history shared by all its members.
- Messages are end-to-end encrypted between the owner and **this process**;
  the plaintext of the conversation (the last `LLM_HISTORY_MESSAGES`
  messages and the system prompt) then goes to the chosen provider and
  nowhere else.
- Chat history and the greeting marker live in `<BOT_STORE_PATH>.llm`,
  encrypted with `BOT_STORE_KEY` (AES-256-GCM, the identity store's format).
  Delete that file to make the bot forget every chat; `/new` forgets one.
- API keys come from the environment only and are sent only to the
  configured base URL (`x-api-key` for Anthropic, `Authorization: Bearer`
  for OpenAI-compatible servers, plus `api-key` for `*.azure.com`). They are
  never logged and never shown in a chat.
- The CLI providers start the vendor CLI with **all tools off where the CLI
  allows it** (`claude --tools ""`) or in a **read-only sandbox** (`codex
  exec --sandbox read-only`; Codex can still read files the user can read),
  in an empty working directory, without saving sessions. The prompt goes
  through stdin, never argv (argv is visible to other users in `ps`).
  Installed by `infra/bots/jay-new-bot.sh` on Linux, the whole bot runs in a
  bubblewrap sandbox: an empty home folder with only the bot folder, the CLI
  and its login visible (spec `2026-11-09-bot-access` A7). On macOS and
  Windows there is no such sandbox; run a CLI bot that answers group members
  under a separate OS user.
- The bot's SQLite session DB is plaintext on disk (see
  `../calltype_bot/README.md`), so the host must be trusted.

## Providers

| `LLM_PROVIDER` | What it uses | Needs | Default model |
| --- | --- | --- | --- |
| `anthropic` | Messages API, `POST /v1/messages`, SSE streaming | `ANTHROPIC_API_KEY` | `claude-sonnet-5-5`, effort `low` |
| `openai` | Chat Completions, `POST {OPENAI_BASE_URL}/chat/completions`, SSE streaming | `OPENAI_API_KEY` (optional off api.openai.com) | `gpt-6.1-sol`, `reasoning_effort` `low` (api.openai.com only; other endpoints need `LLM_MODEL`) |
| `claude-cli` | `claude -p --output-format json` | Claude Code installed and signed in by the owner | the CLI's own setting |
| `codex-cli` | `codex exec` | Codex CLI installed and signed in by the owner | the CLI's own setting |

Why these defaults (checked in the vendors' docs on 2026-11-09): Claude Sonnet
5.5 is Anthropic's "speed and intelligence" tier and Anthropic recommends
`low` or `medium` effort for chat (Sonnet 5.5 defaults to `high`, which is
slower and spends more thinking tokens). GPT-6.1 Sol is OpenAI's recommended
balance of intelligence and cost and supports Chat Completions. Chat
Completions instead of the Responses API because every compatible server
(Azure OpenAI v1, OpenRouter, Ollama, LM Studio, vLLM) implements it and this
bot needs no tools. For cheaper bots: `LLM_MODEL=claude-haiku-5-5` or
`LLM_MODEL=gpt-6-luna`.

Examples of `OPENAI_BASE_URL`: `https://openrouter.ai/api/v1`,
`http://localhost:11434/v1` (Ollama), `http://localhost:1234/v1` (LM Studio),
`https://<resource>.openai.azure.com/openai/v1` (Azure OpenAI, `LLM_MODEL` =
deployment name).

### Subscription providers (Claude Code, Codex): terms

Jay never asks for, stores or forwards a Claude.ai or ChatGPT login or token.
Anthropic does not permit third-party developers to offer Claude.ai login in
their own applications, to route requests through Free/Pro/Max plan
credentials on behalf of their users, or to collect, store or intermediate
Claude.ai credentials; it does allow an end user to sign in to the
unmodified Claude Code binary with their own subscription. See
[Claude Code legal and compliance](https://code.claude.com/docs/en/legal-and-compliance),
the [Consumer Terms](https://www.anthropic.com/legal/consumer-terms) and the
[Usage Policy](https://www.anthropic.com/legal/aup). Advertised plan limits
assume ordinary, individual use.

So the supported path is: **you** install the official CLI on **your**
machine, sign in through the vendor's own flow (`claude`, `codex login`), and
this bridge runs that unmodified CLI as a subprocess for **your own**
messages only. It is personal use; do not make such a bot answer other
people. That is why the CLI providers default to `GROUP_REPLIES=owners`;
`GROUP_REPLIES=members` is your explicit choice and your responsibility
under those terms (and it spends your plan's limits on other people's
questions). For Codex, OpenAI's
[authentication docs](https://developers.openai.com/codex/auth) say ChatGPT
sign-in uses your plan's limits, recommend API key sign-in for programmatic
workflows such as CI, and ask not to expose Codex execution in untrusted or
public environments; the
[ChatGPT plan help article](https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan)
and the [Terms of Use](https://openai.com/policies/terms-of-use/) apply. If you
want a bot for more people or for heavy use, use an API key (`anthropic` or
`openai`): it is the robust path.

## Configuration (environment only)

| Variable | Required | Default | Meaning |
| --- | --- | --- | --- |
| `CALLTYPE_API_URL` | yes | | Jay API base URL |
| `BOT_STORE_KEY` | yes | | base64 of exactly 32 bytes (`openssl rand -base64 32`); encrypts the identity store and the chat history |
| `BOT_STORE_PATH` | no | `/data/bot.store` | identity store; `<path>.sqlite` and `<path>.llm` are created next to it |
| `ALLOWED_HANDLES` | yes | | comma-separated `CT-XXXX-XXXX` handles of the owner(s) |
| `BOT_DISPLAY_NAME` | no | `Jay bot` | the bot's name (`@mention` in groups, greeting) |
| `LLM_PROVIDER` | yes | | `anthropic`, `openai`, `claude-cli`, `codex-cli` |
| `LLM_MODEL` | see table | provider default | model id or CLI alias |
| `ANTHROPIC_API_KEY` | anthropic | | API key from platform.claude.com |
| `ANTHROPIC_BASE_URL` | no | `https://api.anthropic.com` | for a gateway |
| `OPENAI_API_KEY` | openai on api.openai.com | | API key (optional for local servers) |
| `OPENAI_BASE_URL` | no | `https://api.openai.com/v1` | any OpenAI-compatible endpoint |
| `LLM_EFFORT` | no | `low` (Anthropic, api.openai.com), else unset | `output_config.effort` / `reasoning_effort`; `none` = do not send |
| `LLM_SYSTEM_PROMPT` | no | short friendly-assistant prompt (answers in the user's language) | system prompt |
| `LLM_HISTORY_MESSAGES` | no | `20` | messages remembered per chat (user + assistant); `0` = none |
| `LLM_MAX_TOKENS` | no | `8192` | output cap per answer (thinking counts on current Claude models) |
| `LLM_TIMEOUT_SECONDS` | no | `300` | longest wait for one answer |
| `PROGRESS_AFTER_SECONDS` | no | `5` | "Working on it..." after this long, then edited with the streamed text (max 30 edits); `0` = never |
| `CLAUDE_BIN`, `CODEX_BIN` | no | `claude`, `codex` | CLI path (the setup script writes the absolute path, services have a short `PATH`) |
| `LLM_CLI_WORKDIR` | no | `<BOT_STORE_PATH>.cli` | empty working directory of the CLI |
| `BOT_GREETING` | no | `on` | `off` = no first message to the owners |
| `GROUP_REPLIES` | no | `members` (API keys), `owners` (CLI providers) | `members` = in a group with an owner, any human member who addresses the bot is answered; `owners` = owners only |
| `BOT_INBOUND` | no | `owners` | server-side inbound policy: `owners` = the server delivers only owners' 1:1 messages and groups with an owner; `open` = everything (the bot still filters) |
| `PEER_MAX_TURNS_CAP` | no | `50` | ceiling for a bot-only exchange in a group; a group's "max messages" above it is cut down to it |
| `LLM_IMAGE_MAX_BYTES` | no | `5242880` (5 MB) | largest received image passed to the model (max 20 MB) |
| `LLM_IMAGE_MODEL` | no | unset (no image generation) | `LLM_PROVIDER=openai` only: image model of `POST {OPENAI_BASE_URL}/images/generations`, e.g. `gpt-image-1`; any other provider refuses to start with it |

Exit codes: 78 configuration (nothing to retry; the services do not restart
on it), 69 Jay API unreachable, 73 history file not writable.

## What it does

- First start: registers the bot identity, prints `Bot CT-XXXX-XXXX starting,
  invite: ct://...` (the setup scripts wait for this line), then sends each
  owner ONE greeting 1:1: "Ahoj, jsem <name>. Napiš mi." (plus an English
  line). A marker in the encrypted store keeps it from repeating; a failed
  greeting is retried on the next start. The app adds the bot to contacts
  when the owner replies.
- Each owner message: typing indicator, the conversation's last
  `LLM_HISTORY_MESSAGES` messages + the new one go to the provider. API
  providers stream: after `PROGRESS_AFTER_SECONDS` a progress message appears
  and is edited with the partial text every few seconds; the final answer
  replaces it (long answers continue in 4000-character chunks).
- Errors: one apology message with the reason ("Sorry, I could not answer:
  ..."); a refused key says so. A 429 before any text is retried once after
  `retry-after` (max 30 s). Nothing is remembered from a failed turn.
- `/new` forgets this chat; `/help` (and `/start` from a bot link) explains
  the bot. Both are published as the bot's "/" menu.
- Reactions are ignored. Voice messages, other files and tools are out of
  scope (see Images).

## Images (spec `2026-11-10-bot-media`)

- **Receiving**: an image from someone the bot answers anyway (the access
  rules above decide first; nothing is downloaded for anyone else) is
  decrypted by calltype_bot and passed to the model with its caption. In a
  group the image needs a caption with `@bot` or must be a reply to the bot.
  JPEG, PNG, GIF and WebP (typed by their bytes) up to `LLM_IMAGE_MAX_BYTES`;
  no downscaling. Voice messages, videos and other files get a short reply
  saying what the bot can read, without a model call.

  | Provider | How the image goes in |
  |---|---|
  | `anthropic` | `image` content block, base64 |
  | `openai` | `image_url` part with a `data:` URL (the model must support vision; a text-only model's error is shown) |
  | `codex-cli` | `codex exec --image=<file>`; the file is written into `LLM_CLI_WORKDIR` (inside the sandbox) and deleted after the run |
  | `claude-cli` | `--input-format stream-json --output-format stream-json --verbose`, one user message with an `image` block (checked with Claude Code 2.1.319) |

  The history keeps `[image: <name>]` and the caption, never the image, so
  later turns only know that an image was there.
- **Sending** (opt-in, `LLM_PROVIDER=openai` + `LLM_IMAGE_MODEL`): the system
  prompt tells the model to write `[[image: <description>]]` when the user
  asks for a picture. The bridge removes the tag, calls the OpenAI Images
  API (1024x1024, at most 2 per answer, billed to the same key), sends the
  image after the text and deletes the temporary file
  (`<BOT_STORE_PATH>.media`). A failed generation adds a short note.
  Anthropic and the CLIs cannot create images.

## Run

```bash
# once, from the repo root: generate the core's drift code
cd src/client/calltype_core && dart pub get && dart run build_runner build --delete-conflicting-outputs
cd ../../bots/llm_bridge && dart pub get
export CALLTYPE_API_URL=https://calltype-beta-zahy.azurewebsites.net
export BOT_STORE_KEY=$(openssl rand -base64 32)   # keep it; losing it = new identity
export BOT_STORE_PATH=$HOME/.jay-bots/test/bot.store
export ALLOWED_HANDLES=CT-XXXX-XXXX
export LLM_PROVIDER=anthropic
read -rs ANTHROPIC_API_KEY && export ANTHROPIC_API_KEY
dart run bin/llm_bridge.dart
```

Native bundle (what the release workflow ships): `dart build cli -o out`
gives `out/bundle/bin/llm_bridge` + `out/bundle/lib/` (sqlite). Docker:

```bash
docker build -f src/bots/llm_bridge/Dockerfile -t llm-bridge src
docker run -d --restart unless-stopped -v jay-bot:/data --env-file bot.env llm-bridge
```

## Tests

`dart test`: config rules, both HTTP providers against a loopback fake
(request shape, streaming, errors, 429), both CLI providers with fake
executables (argv, stdin, timeout kill, non-zero exit), the turn logic
(history cap, `/new`, progress edits, chunking, retry, timeout) and the real
bot runtime with the calltype_bot test fakes (owner-only before decrypt,
group members of owner groups, inbound policy, greeting once, images in and
out). `images_test` covers image intake, request bodies, generation and the
image settings. `access_test`
covers who is answered (A4/A5) without a hub.
