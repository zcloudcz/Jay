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
  -e CALLTYPE_API_URL -e BOT_STORE_KEY -e HERMES_API_KEY -e ALLOWED_HANDLES hermes-bridge
```

## Hermes contract: verified vs assumed

Everything Hermes-specific lives in `HermesClient.ask` (`lib/hermes_bridge.dart`).

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
