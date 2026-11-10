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
- At start the bridge publishes a server-side inbound policy (owners = the resolved
  `ALLOWED_HANDLES`): the server then does not even store 1:1 messages from other
  people, nor group messages of groups without one of the owners. `BOT_INBOUND=open`
  turns that off (the bridge still filters every sender itself). An old server
  without the policy is logged and ignored.
- The local `/send` and `/react` endpoint is **off** unless `BRIDGE_SEND_KEY` is set, binds to
  127.0.0.1 only, and sends 1:1 messages and reactions only to `ALLOWED_HANDLES`. Channel posts
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
| `HERMES_ASK_TIMEOUT_SECONDS` | no, default `300` | longest wait for a Hermes answer (`/chat`), or longest silence while streaming; raise it for long agent turns |
| `HERMES_TIMEOUT_SECONDS` | no | older name of `HERMES_ASK_TIMEOUT_SECONDS`, still read when the new one is unset |
| `JAY_SERVER_TIMEOUT_SECONDS` | no, default `60`, min `20` | the Jay hub pings every 15 s; this long without any frame from it = dead session, the bridge logs it and reconnects (same identity) |
| `ALLOWED_HANDLES` | effectively yes | comma-separated `CT-XXXX-XXXX` handles allowed to talk to Hermes |
| `PEER_BOT_HANDLES` | no | comma-separated handles of other bots; if set, ONLY these may talk to this one (narrows the group setting, never widens it; set but unresolvable = no bot) |
| `BOT_INBOUND` | no, default `owners` | `owners` = the server delivers only owners' 1:1 messages and groups with an owner as member; `open` = the server delivers everything (the bridge still filters) |
| `PEER_MAX_TURNS_CAP` | no, default `50` | operator ceiling for a bot-only exchange; a group's "max messages" above it is cut down to it |
| `BRIDGE_SEND_KEY` | no | enables `POST http://127.0.0.1:$BRIDGE_PORT/send` and `/react`; the Bearer key callers must send. Unset = endpoint off |
| `BRIDGE_PORT` | no, default `8650` | port of the local send endpoint (loopback only) |
| `HERMES_STREAM` | no, default `true` | stream turns (`/api/sessions/{id}/chat/stream`, SSE): progress and approval buttons. `false` = plain `/chat`. A Hermes without the stream route is detected (404 after the session exists) and `/chat` is used from then on |
| `PROGRESS_AFTER_SECONDS` | no, default `8` | post "Working on it..." when no answer came after this long; `0` = never |
| `PROGRESS_EDIT_SECONDS` | no, default `5` | min seconds between progress edits (current tool) |
| `PROGRESS_MAX_EDITS` | no, default `30` | progress edits per turn; then it stays until the answer replaces it |
| `BOT_COMMANDS` | no | `cmd:description;cmd2:description` published as the bot's "/" menu at start (a bad entry stops the start; an old server without the endpoint is logged and ignored) |
| `REACTION_MODE` | no, default `silent` | what an owner's emoji reaction in Jay does: `silent` (one Hermes turn, the answer is not posted), `batch` (no turn; sent along with the owner's next message), `reply` (normal turn, the answer is posted), `off`. See "Reactions" below; an unknown value stops the start |
| `MEDIA_MODE` | no, default `on` | `off`: received files are not processed, Hermes sees only the sender's fallback text (as before). See "Voice messages, images and files" |
| `MEDIA_DIR` | no, default `media` next to `BOT_STORE_PATH` (`/data/media` in the image) | where received files are saved, one folder per message, mode 700 |
| `MEDIA_MAX_BYTES` | no, default `200000000` | larger files are not downloaded, Hermes gets only their metadata |
| `MEDIA_RETENTION_DAYS` | no, default `7` | saved files are deleted after this many days (checked at start and every 6 h) |
| `STT_ELEVENLABS_API_KEY` | no | ElevenLabs API key for transcribing voice messages and audio (Speech-to-Text, language auto-detected). `ELEVENLABS_API_KEY` is read when this is unset. No key = Hermes gets a note that a voice message arrived but cannot be transcribed, plus the file path |
| `STT_MODEL` | no, default `scribe_v2` | ElevenLabs STT model (`scribe_v1` also works) |
| `STT_MAX_SECONDS` | no, default `600` | longer voice/audio (sender-declared duration) is not transcribed, only saved |
| `STT_MAX_BYTES` | no, default `25000000` | larger voice/audio is not transcribed, only saved |
| `IMAGE_INPUT` | no, default `true` | images (JPEG, PNG, GIF, WebP) up to `IMAGE_MAX_BYTES` go to Hermes as image input (`image_url` content part); `false` = saved and passed as a path |
| `IMAGE_MAX_BYTES` | no, default `5000000` | larger images are saved and passed as a path (Hermes' request body cap is 10 MB, the image travels base64) |
| `MEDIA_SEND` | no, default `on` | `off`: replies are text only, `MEDIA:` lines and `[voice]` stay in the text (as before). See "Sending files and voice replies" |
| `MEDIA_SEND_ROOTS` | no, default: Hermes' media dirs under `HERMES_HOME` (`~/.hermes`): `image_cache`, `audio_cache`, `video_cache`, `document_cache`, `browser_screenshots`, `cache/{images,audio,videos,documents,screenshots,generated,scratch}`, plus `MEDIA_DIR` | comma-separated absolute directories the agent may send files from; a file is sent only when its real path (symlinks and `..` resolved) is inside one. Missing directories are skipped |
| `MEDIA_SEND_MAX_BYTES` | no, default `200000000` | larger files are not sent |
| `VOICE_REPLY_MODE` | no, default `auto` | `auto`: the answer is also spoken when the owner sent a voice message, asked for a voice reply ("odpověz hlasovkou", "reply with a voice message") or the agent wrote `[voice]`; `always`: every answer to an owner; `off`: never. An unknown value stops the start |
| `VOICE_REPLY_WITH_TEXT` | no, default `true` | a voice reply also posts the text; `false` = voice only (the text still goes out when the TTS fails) |
| `ELEVENLABS_VOICE_ID` | no | ElevenLabs voice for voice replies. No voice id or no key = no voice replies (logged at start) |
| `TTS_ELEVENLABS_API_KEY` | no | ElevenLabs key for Text-to-Speech; `ELEVENLABS_API_KEY` is read when unset |
| `TTS_MODEL` | no, default `eleven_v4` | ElevenLabs TTS model |
| `TTS_MAX_CHARS` | no, default `2500` | longer answers are spoken up to the last sentence end before this (the full text is posted anyway) |
| `FFMPEG_PATH`, `FFPROBE_PATH` | no, default `ffmpeg` / `ffprobe` on `PATH` (the image has them) | converts voice replies to AAC `.m4a`, adds duration, waveform and thumbnails. Without ffmpeg voice goes as MP3 (plays on every client), without waveform |
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

## Voice messages, images and files

Jay sends voice messages, audio, video, large files and (newer apps) images as encrypted media (spec
`docs/superpowers/specs/2026-11-07-encrypted-media.md`): the message carries the key, the server keeps only ciphertext
for 72 h. Small photos still come as an old inline `file` message. For an OWNER's message the bridge downloads,
decrypts and verifies the file (calltype_core chunk format, SHA-256) and Hermes reads:

| Received | Hermes sees (the caption, if any, follows on the next line) |
| --- | --- |
| voice message | `[hlasová zpráva 0:10, přepis]: <transcript>` |
| audio file | `[zvuková nahrávka song.mp3 3:20, přepis]: <transcript>` |
| voice/audio, no STT key | `[hlasová zpráva 0:10: přepis není k dispozici, bridge nemá nastavený ELEVENLABS_API_KEY; soubor: <path>]` |
| voice/audio over 10 min / 25 MB | `[hlasová zpráva 12:30, 3.1 MB: příliš dlouhá na přepis (limit 10 min / 25.0 MB); soubor: <path>]` |
| image (JPEG/PNG/GIF/WebP, up to 5 MB) | `[obrázek photo.jpg, 120 KB]` + the image itself as an `image_url` part |
| other image, or `IMAGE_INPUT=false` | `[obrázek: photo.heic, 2.1 MB, image/heic, <path>]` |
| video, any other file | `[soubor: clip.mp4, 12.4 MB, video/mp4, <path>]` |
| file over `MEDIA_MAX_BYTES` | `[soubor: big.zip, 300 MB, application/zip, nestaženo: nad limit 200 MB]` |
| expired / damaged download | `[... : stažení selhalo: platnost na serveru vypršela]` (or `soubor je poškozený`) |

- Transcription: ElevenLabs Speech-to-Text (`POST /v1/speech-to-text`, model `STT_MODEL`), language detected
  automatically. A failing STT call becomes a note with the file path; the turn still runs.
- Saved files: `MEDIA_DIR/<message id>/<file name>`, folder mode 700, deleted after `MEDIA_RETENTION_DAYS`. Hermes
  runs on the same host (or shares the volume) to open the path; in Docker mount `/data` where Hermes can read it, or
  treat the path as informational.
- Files from other bots (group bot talk) are never downloaded: Hermes gets only the metadata line.
- The images are stored in the Hermes session like any user message (base64 in Hermes' session store).
- `MEDIA_MODE=off` restores the old behaviour (fallback text only, inline files ignored).

## Sending files and voice replies

The bridge sends files with the bot runtime's `sendFile` (calltype_bot): encrypted with a fresh key in the app's chunk
format (calltype_core `MediaCipher`), streamed from disk to the media relay, so every Jay client shows it like a file a
person sent. Small images (JPEG/PNG/GIF/WebP up to 256 KiB) go inline like the app's photos and show without a
download tap. The server's 5 GB cap and per-device quotas apply; `MEDIA_SEND_MAX_BYTES` is the bridge's own cap.

In Hermes' answer, these are taken out of the text and sent:

| In the answer | Sent as |
| --- | --- |
| a line or token `MEDIA:/abs/path` (Hermes' convention; quoted with backticks or quotes when the path has spaces) | a file; the kind (image, video, audio, file) comes from the name |
| `[file:/abs/path]` | the same |
| `[voice:/abs/path]`, or an audio `MEDIA:` with Hermes' `[[audio_as_voice]]` | a voice message (converted to AAC `.m4a`) |
| `[voice]` | the answer is also spoken (TTS) and sent as a voice message |

- Tags in code blocks, inline code or quoted lines (`> ...`) are left alone, so the agent can explain the syntax.
- One file and a short text (up to 1024 characters): the text becomes the file's caption. Otherwise the text is posted
  first, then the files.
- Allowed roots: only files whose REAL path lies in `MEDIA_SEND_ROOTS` are sent. `../` and symlinks pointing out of a
  root are refused, as are missing files, directories and files over the cap. A refused file is logged
  (`File <path> for message <id> refused: ...`) and the owner gets `Soubor se nepodařilo poslat: <name>: <reason>`.
  WHY: the answer is untrusted text; a prompt injection must not be able to mail out `~/.ssh` or the bridge env.
- Voice replies (`VOICE_REPLY_MODE`, ElevenLabs TTS with `ELEVENLABS_VOICE_ID`, model `eleven_v4`): the answer without
  markdown, code and links is spoken, converted to AAC-LC mono 44.1 kHz `.m4a` (`audio/mp4`, what the app records and
  plays on iOS, Android, macOS, Windows and web) with duration and a 64-bar waveform, and sent after the text. When the
  owner's turn will be spoken, Hermes is told so in front of the message (write it to be read aloud). A failing TTS is
  logged; with `VOICE_REPLY_WITH_TEXT=false` the text is then posted instead.
- Without ffmpeg the voice goes as the TTS's MP3 (`audio/mpeg`), which the app also plays everywhere, without waveform.
- Hermes learns the syntax once per conversation (per bridge run) from a hint in front of the owner's first message,
  next to the `[react:EMOJI]` hint.
- Only owners' turns get voice replies; files may also go to a group in a bot exchange (they count like a text answer).

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

## Reactions

Owners can react to the bot's messages with an emoji (long-press / message
menu in Jay) to give quick feedback without writing. Spec:
`docs/superpowers/specs/2026-11-07-message-reactions.md`.

- Hermes sees one line per reaction, in the conversation's own session:
  `[from CT-XXXX-XXXX] [reaction 👍 to your message: "<first 200 chars>"]`
  (`to a message` when the bot no longer remembers the text; it keeps the
  start of its last 500 messages in its local store for this).
- Only `ALLOWED_HANDLES` owners count. Removing a reaction, and reactions of
  other bots, are ignored (no bot-to-bot loops). In groups only reactions to
  the bot's own messages arrive at all.
- `REACTION_MODE=silent` (default): one Hermes turn per reaction with the
  hint that the answer is not shown; the answer is discarded, there is no
  progress message, and an approval Hermes asks for in that turn is DENIED.
  Costs one agent turn per reaction.
- `batch`: no turn. Notes are kept in memory per conversation (at most 20,
  lost on restart) and put in front of the owner's next message.
- `reply`: like `silent` but the answer is posted into the chat (approvals are
  still denied).
- `off`: ignored.
- A reaction waits behind a turn already running in its conversation.

### The bot reacting: `[react:EMOJI]`

Hermes can answer with a reaction instead of (or besides) text. When the
FIRST non-blank line of its final answer is exactly `[react:EMOJI]` (spaces
around it and any case of `react` are fine), the bridge puts EMOJI on the
owner's message being answered and posts only the rest:

```
[react:👍]
Deployed to beta.
```

- EMOJI must be ONE emoji (skin tones, ZWJ families, flags and keycaps are
  one emoji); `[react:]` removes the bot's reaction.
- An answer of only that line posts no text. If a progress message is
  already on screen it is edited to "Done." (a bot cannot delete it).
- An invalid emoji (`[react:yes]`, two emojis) is stripped and logged, never
  shown; the rest of the answer is posted (nothing left = the usual apology).
- Only the first line counts: `[react:...]` further down, or followed by
  text on the same line, is ordinary text.
- Works in 1:1 and in groups (the reaction goes to the addressed message).
  Not applied in reaction turns: `silent` discards the answer anyway,
  `reply` strips the line and posts the rest.
- Hermes learns the syntax from a one-sentence hint put in front of the
  first owner message of each conversation after a bridge start.

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

### Files and voice messages over `/send`

```bash
# a file (absolute path under MEDIA_SEND_ROOTS), optional caption / kind / text
curl -sS -X POST http://127.0.0.1:8650/send -H "Authorization: Bearer ***" -H 'Content-Type: application/json' \
  -d '{"to": "CT-XXXX-XXXX", "file": "/home/me/.hermes/cache/documents/report.pdf", "caption": "report"}'
# a voice message: the text is spoken with the TTS (nothing else is posted)
curl -sS -X POST http://127.0.0.1:8650/send -H "Authorization: Bearer ***" -H 'Content-Type: application/json' \
  -d '{"to": "CT-XXXX-XXXX", "text": "Deploy je hotovy.", "voice": true}'
```

Fields: `file` (absolute path), `kind` (`image`, `video`, `audio`, `voice`, `file`; default from the name), `caption`
(max 4096), `voice` (`true`: the file as a voice message, or without a file the `text` spoken), `text` (with a file:
posted as a normal message first). Same targets and rules as text (owners' handles, groups the bot is in; no
channels). Extra statuses: 403 `file_not_allowed` (outside the roots, missing, not a regular file), 413
`file_too_large`, 503 `media_unavailable` (`MEDIA_SEND=off`, or `voice` without a TTS key and voice id), 400
`bad_target` for a channel.

### Reacting from outside: `/react`

Same port, same key, same body cap. Puts an emoji on a message (`""` removes
the bot's reaction):

```bash
curl -sS -X POST http://127.0.0.1:8650/react \
  -H "Authorization: Bearer $BRIDGE_SEND_KEY" -H 'Content-Type: application/json' \
  -d '{"to": "CT-XXXX-XXXX", "emoji": "✅"}'
```

`to` is an `ALLOWED_HANDLES` owner (1:1) or a group the bot is in (a
reaction addresses nobody, so unlike a group `/send` it is not a bot turn);
channels take no reactions. `messageId` is optional: without it the bridge
reacts to the last message it received from that owner or in that group
(kept in memory, empty after a restart).

| Status | Meaning |
| --- | --- |
| 202 | `{"status": "reacted"}` |
| 400 | body is not `{"to": string, "messageId"?: string, "emoji": string}` (messageId 1..64 characters); `invalid_emoji`: not ONE emoji and not `""`; `bad_target`: a `channel:` target |
| 401 | missing or wrong key |
| 403 | `target_not_allowed`: a handle not in `ALLOWED_HANDLES`, or a group the bot is not in |
| 404 | `no_message`: no `messageId` and no message from that target since the start; also an unknown path |
| 405 | wrong method |
| 502 | allowed, but the hub did not take it (retry later) |

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
