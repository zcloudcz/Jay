# Bot conversations: bots talking to each other in a group (design)

Status: draft, owner Martin, prepared by Hermes Dev 2026-11-05.
Branch: `feat/bot-conversations`.

## Why

Two Hermes agents (Hermes Dev, Hermes Ops) need to hand work to each other ("deploy 28f5070", "done") without Martin copying
messages. Today the Hermes bridge has a global, env-only peer list (`PEER_BOT_HANDLES`, groups only, 5 turns / 30 min) and a bot
can only *reply*; it can never start a message. The group owner, not the bot operator's env file, should decide which bots in
which group may talk, how long and how often. Artifacts (tarballs, reports) stay in git; Jay carries the signal.

## Decisions (Martin 2026-11-04/05)

| # | Decision |
|---|---|
| D1 | Per-group setting "Bot conversation": **Off** (default) / **All bots** / **Selected bots**. |
| D2 | "All bots" includes bots added to the group later. |
| D3 | Max length of a bot-only exchange (bot messages in a row without a human) is a group setting. |
| D4 | Pause between bot-only exchanges is a group setting. |
| D5 | A bot takes part in bot talk only in a group where its **owner** (a handle from the bot's `ALLOWED_HANDLES`) is an **admin**. |
| D6 | Any user may **mute** any conversation (group or 1:1) so bot chatter is not annoying. |

## Group setting (server)

New owned type on `Group` (plaintext metadata, like membership and roles; message content stays E2E):

```
BotTalk {
  Mode: "off" | "all" | "selected"        // default "off"
  AllowedBotDeviceIds: Guid[]              // used when Mode = "selected"; only bot members
  MaxBotTurns: int                         // default 5, 1..50
  PauseMinutes: int                        // default 30, 0..1440
  UpdatedBy: Guid, UpdatedAt: DateTimeOffset
}
```

- `GET /groups/{id}` returns `botTalk`; `PUT /groups/{id}/bot-talk` changes it, **admin only** (same gate as add/remove member).
- Validation: ranges above; `selected` ids must be current members with `IsBot`; removed members are dropped from the list on
  removal. One migration (`AddGroupBotTalk`, `--context AppDbContext`), additive.
- Hub sends the existing "group changed" hint after a change so clients and bots re-read.
- Business groups: same setting; the auditor member is never a bot participant.

## Enforcement (every bot, client side)

The server cannot see content, so each bot enforces the rules itself. A misbehaving bot is contained because the *receiving*
bot also refuses.

A bot handles a message from another bot in group G only if all hold:
1. G's `botTalk.mode` is `all`, or `selected` and **both** the sender and this bot are in `AllowedBotDeviceIds`.
2. One of this bot's owners (`ALLOWED_HANDLES`) is an `admin` member of G (D5).
3. The exchange counter for G is below `MaxBotTurns` and below the bridge's hard cap `PEER_MAX_TURNS_CAP` (env, default 50);
   the group cannot raise a bot above its operator's cap.
4. If the previous exchange in G ended less than `PauseMinutes` ago, a *new* exchange may not start.

Definitions: an **exchange** starts with the first bot message after a human message (or after the pause) and counts bot
messages in G. Any message from a human member that mentions a bot **resets** the counter and the pause. When the limit is
hit the bot sends one notice ("Bot limit reached, waiting for a human") and stays silent.

1:1 chats between two bots stay refused (nobody watching), as today.

`PEER_BOT_HANDLES` becomes optional: if set, it is an extra operator-side allowlist intersected with the group setting
(operator can only narrow, never widen).

## Bots can start a message

- `calltype_bot`: `Future<void> send({required String to, required String text})` where `to` is a handle (1:1, must be an
  allowed human) or a group id (bot must be a member). Same encryption path as `reply`; counts as a bot turn in groups.
- `hermes_bridge`: local HTTP endpoint `POST http://127.0.0.1:${BRIDGE_PORT:-8650}/send` with `Authorization: Bearer
  ${BRIDGE_SEND_KEY}` (fail-closed: no key = endpoint off), body `{"to": "...", "text": "..."}`; 202 on queued, 403 when the
  target is not allowed by the rules above. Lets Hermes tools and cron jobs post into Jay (today cron cannot deliver to Jay).
- Text only. Artifacts are referenced (git commit/file path), not attached.

## Mute (D6)

- Per device, per conversation: `Muted` = off / **bots only** / all, optional until-time.
- Stored on the server per membership (`PUT /groups/{id}/mute`, `PUT /conversations/{deviceId}/mute` for 1:1) so
  `PushNotificationService` skips the push; the server already knows `IsBot` of the sender, so "bots only" needs no content.
- Client: bell icon in the conversation header + long-press in the list; muted conversations show an icon and do not count
  into the app badge.

## Client UI (Flutter)

Group detail (admin): section "Bot conversation" with the three modes, bot checklist (members with BOT badge), two number
fields (max messages, pause). Non-admins see it read-only. Strings through l10n.

## Tests

- Server: endpoint auth (admin only), validation, member removal prunes list, migration, push skip for mute modes.
- Bot runtime: `send()` 1:1 and group; settings re-read on hint.
- Bridge: rules 1-4 table-driven (incl. owner not admin, selected without self, cap < group max, pause), notice once,
  human reset, `/send` auth and 403.
- Live E2E against docker-compose: two bridges with a fake backend in one group, Off -> All -> Selected, limit and pause.

## Out of scope

Attachments for bots, bot-to-bot 1:1, server-side enforcement of content-level rules.
