# llm_bridge: public 1:1 mode (demo bot)

Status: implemented on `feat/bot-public-dm` (not released).
Owner approval: demo bot for the App Store reviewer, 2026-11-27.
Builds on `2026-11-09-bot-access` (A3 inbound policy, A4/A5 groups, A7
actions) and `2026-11-12-llm-bridge-fallback-rescue` (actions).

## Why

App Review needs a bot it can talk to without being one of its owners. Today
`llm_bridge` answers only owners in 1:1 (`LlmAccess.decide`), and strangers
are dropped before decryption. A demo bot must answer anyone in 1:1 while a
flood of strangers cannot burn the owner's key or subscription.

## Decisions

| # | Decision |
| --- | --- |
| P1 | New setting `PUBLIC_DM=on\|off`, default `off`. Off = behaviour exactly as before. |
| P2 | With `PUBLIC_DM=on` the bot publishes the server inbound policy `open` (as if `BOT_INBOUND=open`). `BOT_INBOUND=owners` together with `PUBLIC_DM=on` is a config error (exit 78): the server would never deliver a stranger's message. |
| P3 | 1:1 from ANY sender is admitted before decryption (new runtime hook `allowDirectSender`, consulted only when `allowSender` refused and the message has no group). Groups keep the owner rules of A4/A5 unchanged: the hook is never asked for group messages. |
| P4 | Owners keep everything: no limits, actions (A7), image generation, greeting. |
| P5 | Strangers (non-owners) in 1:1: never actions (A7 rule `groupId == null && owner`, unchanged), never image generation (no image hint in their prompt, `[[image: ...]]` stays text), no greeting. llm_bridge has no owner-only settings or commands; `/new` and `/help` act only on the sender's own conversation. Received images are passed to the model as for owners (same size limit). |
| P6 | Per-sender limit `LLM_PUBLIC_RATE` (default 20 messages per sliding hour). Over it: ONE polite notice per sender per hour, then silent drops. No model call. |
| P7 | Global cap `LLM_PUBLIC_DAILY` (default 200 stranger messages per sliding 24 h, owners not counted). Over it: the same one-notice-per-hour rule with the daily text. |
| P8 | Peer bots in 1:1 (sender profile `isBot`, from `GET /devices/{id}/profile`, never key-bundle): treated as strangers, but limited by `LLM_PUBLIC_BOT_RATE` (default 5 answers per peer bot per hour) and NEVER sent a limit notice (a notice is a message another bot could answer: ping-pong). Reactions still never start a turn. A failed profile lookup counts as a bot (stricter limits, fail closed). |
| P9 | History: one conversation per sender identity, as today (`conversationId` = identity), so strangers never see each other or the owner. |
| P10 | Logging: one line per stranger message, `Public 1:1: <handle or id> (<human\|bot>): <answered\|limit notice\|dropped: reason>`. Never content. |
| P11 | Scripts: `jay-new-bot.sh --public-dm` / `--no-public-dm`, `jay-new-bot.ps1 -PublicDm` / `-PublicDm:$false`. A rerun keeps the stored value and any hand-tuned `LLM_PUBLIC_*` limits. Refused with `--provider hermes` and `--rescue-hermes`. A WARNING in the output when on (strangers spend the key/plan, stronger for CLI subscriptions). Dry-run prints `Public 1:1: on (...)`. |

## Wire / config

Environment (`bot.env`):

| Variable | Default | Meaning |
| --- | --- | --- |
| `PUBLIC_DM` | `off` | `on` = answer anyone in 1:1 (P1-P3) |
| `LLM_PUBLIC_RATE` | `20` | messages per stranger per hour (>= 1) |
| `LLM_PUBLIC_DAILY` | `200` | stranger messages of all senders per 24 h (>= 1) |
| `LLM_PUBLIC_BOT_RATE` | `5` | answers per peer bot per hour (>= 0, 0 = never answer bots in 1:1) |

Runtime (`calltype_bot`), additive and backward compatible:

- `onMessage(..., bool Function(String identity)? allowDirectSender)`.
- `Future<BotPeerProfile?> peerProfile(String identityId)`: handle, display
  name, `isBot` from `GET /devices/{id}/profile`, cached per process.

Notice texts (Czech first, like the greeting):

- sender: `Omlouvám se, dosáhli jste limitu zpráv pro tohoto bota. Zkuste to prosím za hodinu.` + English line.
- daily: `Tento bot dnes dosáhl svého denního limitu zpráv. Zkuste to prosím později.` + English line.

## Limits

- Counters live in memory: a bot restart resets them.
- The encrypted history file grows with every stranger (each conversation
  capped at `LLM_HISTORY_MESSAGES`); the daily cap bounds the growth rate,
  nothing expires old stranger chats yet. Delete `<store>.llm` to reset.
- A stranger can create many identities; the daily cap is the real bound.
- The model still sees whatever a stranger writes (prompt injection is
  harmless only because strangers have no actions and no image generation).
