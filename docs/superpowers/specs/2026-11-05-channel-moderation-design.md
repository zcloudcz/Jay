# Channel moderation (operator web) and bot publishers (design)

Status: approved by Martin 2026-11-05 ("Vypracuj specs a implementuj + release. Text podminek vypracuj, udelej research u konkurence"; admin "jen na web", not in the app). Prepared by Hermes Dev.
Branch: `feat/channel-moderation`. Exact names: `2026-11-05-channel-moderation-contract.md`. Research:
`~/.claude/jarvis/research/2026-11-05-jay-moderace-kanalu-web.md` (Ozone, Mastodon, review-queue pattern, DSA, Telegram/WhatsApp/Discord/Threema/Viber terms).

## Why

Channels are public plaintext. Today a report only lands in `ChannelReports` and a Warning log; the operator has no role,
no endpoint and no UI, a takedown needs SQL, the reporter never learns the outcome and the owner never learns why. The
DSA obliges every hosting provider, also a micro enterprise, to run notice and action (Art. 16), give a statement of
reasons (Art. 17) and publish clear rules (Art. 14). Separately, Martin wants bots to post to channels (newsletters),
which the admin role allows only with far too many rights.

## Decisions

| # | Decision | Why / precedent |
|---|---|---|
| D1 | Rules for channels and bots: `docs/legal/pravidla-kanalu.md` (cs, binding) + `channel-rules.md` (en), web `jay.zcloud.cz/legal/channels-{cs,en}.html`, rule ids K1..K10. Decisions cite a rule id or a legal ground. | Art. 14, Art. 17(2)(d,e); numbered like Discord's guidelines, scope like WhatsApp Channels Guidelines |
| D2 | Operator web at `jay.zcloud.cz/admin/` (separate Flutter web package `src/client/jay_admin`, built into the same Static Web App under `/admin`). Not in the app, no new Azure resource, no DNS change. | Martin: web only. A subdomain would need DNS (WEDOS, hard-stop) and a new SWA |
| D3 | Operator = Jay account listed in `Moderation:OperatorAccountIds` with TOTP MFA enabled. `POST /admin/session` (email + authKey + TOTP/backup code) returns a short-lived operator token (`scope=moderation`, 30 min). It is accepted ONLY on `/admin/*`; device tokens are refused there. No device is registered for the web. | Reuses account auth + MFA; no messenger device cluttering the account; token separation prevents an operator token acting as a device and vice versa |
| D4 | Report-centric data, subject-grouped queue (one row per channel or post) for a single operator; queues/assignment later. Images blurred until clicked. | Ozone, review-queue pattern, moderator wellbeing |
| D5 | Actions: dismiss, remove_post, suspend_channel (1..365 days), terminate_channel, restore_channel. Every action except dismiss requires ground (`terms` + rule id, or `illegal` + legal ground) and an explanation; it creates a `ModerationDecision` (immutable audit row) and a statement of reasons for the owner. Reports of the subject are resolved with the decision. | Art. 17, Mastodon graduated actions, audit |
| D6 | The owner/admins see statements in the app (channel profile, "Moderation" section); the reporter sees outcome in the app ("Reports I filed"); a reporter e-mail (optional) is shown to the operator for a manual reply. No e-mail infrastructure. | Art. 16(5), 17(3) durable medium in-app; API has no mail sender |
| D7 | Reports gain `category` (illegal / terms / spam), optional `contactEmail`, `goodFaith` (required for illegal). Old clients without category keep working (`terms`). | Art. 16(2) |
| D8 | Suspended channel: hidden from followers (posts 403 `channel_suspended`), no posting, no new follows; owner/admins still read it and see the statement. Terminated = existing soft delete + `ChannelDeleted` hub event. | Mastodon suspend/limit |
| D9 | New channel role `publisher` (human or bot): publish + delete own posts only. Owner sets it like admin (`PUT .../admins/{deviceId}` with `role`), also for devices outside contacts (app resolves handle). | Telegram per-right admin (`can_post_messages`) |
| D10 | Posts by a bot device are labelled (`byBot`) in the app. Bot posts limited per channel per bot (`Channels:MaxBotPostsPerDay`, default 20) -> 429 `bot_post_limit`. | Mastodon "Automated" flag, K10 |
| D11 | `calltype_bot.postToChannel`, Hermes bridge `/send` accepts `channel:<handle>`; the server is the authority (role + limit). Newsletter = Hermes cron calling `/send`. | |
| D12 | Out of scope: automated moderation (rule 5 of the rules: human only), report notification push to the operator (no sender reachable from Azure; the web shows counts), appeals workflow (Art. 20 not applicable to micro enterprises; redress by e-mail per rules section 6), approval of bot drafts with buttons (F3), transparency reports. | |

## Security

- Operator endpoints: allowlist + TOTP every 30 min, rate limit "auth" on session, "api" elsewhere; every decision is an
  append-only row with operator account id. The admin web sets `X-Frame-Options: DENY`, `noindex`, no cache for index.
- Reporter identity never leaves the server: not to owners, not in the admin API (the operator sees count, category,
  reason and the optional contact e-mail the reporter chose to give).
- Publisher cannot change the channel profile, admins or others' posts. A bot is never admin by default.

## Tests

Server: session (non-operator 403, no MFA 403, bad code 401, token only on /admin, device token 403 on /admin), queue
grouping and filters, each action's effects (post tombstone, suspension hides posts and blocks posting/follow, terminate,
restore), statements visible to owner only, reporter outcome, report categories and old-client compatibility,
publisher rights, bot label and daily limit. Core/app: DTO parsing, report form, statements, my reports, roles UI, BOT
label. Admin web: login flow, queue, detail, decision with confirmation (widget tests with a fake API). Bot: postToChannel,
bridge `/send channel:`. Live E2E against docker-compose: operator session (TOTP), report -> decision -> owner statement
-> reporter outcome; bot publisher posts, label, limit.
