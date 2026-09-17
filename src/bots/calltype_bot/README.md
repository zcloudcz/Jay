# calltype_bot

Headless CallType (Jay) bot runtime. A bot is an ordinary E2E device — own
`CT-XXXX-XXXX` handle, own keys — built on the same `calltype_core` protocol
code as the app. The server stays an opaque relay; the plaintext is visible to
whoever runs the bot, like for any other peer. Pure Dart, no Flutter SDK.

```dart
final bot = await CallTypeBot.start(
  apiBaseUrl: 'https://…',
  storePath: '/data/bot.store',   // + /data/bot.store.sqlite next to it
  displayName: 'Hermes',          // BOT_STORE_KEY is read from the environment
);
print(bot.handle);                // handle + ct:// invite are also logged on first start
await bot.onMessage(
  (msg) async => msg.reply('you said: ${msg.text}'),
  allowSender: (deviceId) => true, // optional; checked BEFORE decryption
);
```

`onMessage` connects. It is deliberately the step that goes online: the server
pushes everything queued the moment a device connects.

## What the runtime guarantees

- **Registration** with `isBot: true` on first start; identity is reused afterwards.
- **Sessions** are established from the first incoming pre-key message.
- **At-most-once handling.** The message UUID is committed to SQLite in the same
  transaction as the ratchet advance. A replay (lost ack, reconnect, restart,
  crash mid-handler) is acknowledged but never reaches the handler again.
- **Ack after the handler finished**, typing indicator while it runs.
- **Groups:** the handler runs only when the text mentions `@<handle>` or
  `@<display name>`. Replies use the per-member fan-out like the app.
- **Ordering:** handlers run serially per conversation, concurrently across conversations.
- **Handler exception** → logged, short apology sent, loop continues.
- **Reconnect forever** (the app gives up after four attempts; a bot has no user to tap retry).

## Storage and its limits

| File | Content | Protection |
| --- | --- | --- |
| `<storePath>` | identity keys, pre-keys, device secret | AES-256-GCM, key = `BOT_STORE_KEY` (base64, exactly 32 bytes; `openssl rand -base64 32`), atomic temp-file + rename |
| `<storePath>.sqlite` | Double Ratchet sessions, pinned peer identities, seen message ids | **plaintext on disk — exactly like the app's drift DB today** |

So `BOT_STORE_KEY` protects the long-term identity, **not** the session state:
the host running the bot must be trusted. Message bodies are not stored.
Losing the store = a new bot identity (contacts see a different device).
A wrong key refuses to start rather than silently creating a new identity.

## Known gaps (protocol, not runtime)

- **No one-time pre-key replenishment:** the server has no endpoint to upload
  more (the app cannot either). After the initial 100 are consumed, new
  sessions fall back to X3DH without a one-time key, which the protocol supports.
- **"Replied to the bot" is not detectable:** the message payload has no
  reply-to field, so in groups only mentions trigger the bot.
- Text only; attachments and calls are ignored (acknowledged, not handled).

## Tests

`dart test` — no Docker. The runtime tests use two real crypto stacks (a fake
user on the real `SessionManager` ↔ the bot) over a fake hub transport and a
loopback REST fake. A test against the real API is not included: it needs PostgreSQL.

Generate the core's drift code first:
`cd ../../client/calltype_core && dart pub get && dart run build_runner build --delete-conflicting-outputs`.
