# Contract: channel moderation + bot publishers (feat/channel-moderation)

Every layer codes against this file. Design: `2026-11-05-channel-moderation-design.md`. Rules: `docs/legal/pravidla-kanalu.md`.
JSON is camelCase. Errors keep the channel endpoints' shape `{"error": "<human text>", "code": "<machine code>"}`.
Timestamps ISO-8601 UTC. Ids are lower-case GUID strings.

## 1. Constants

- Rule ids: `K1`..`K10` (exactly these 10 strings). Rules URL: `https://jay.zcloud.cz/legal/channels-{cs|en}.html#K<n>`.
- Report categories: `illegal`, `terms`, `spam`.
- Decision actions: `dismiss`, `remove_post`, `suspend_channel`, `terminate_channel`, `restore_channel`.
- Decision grounds: `terms` (requires `rule`), `illegal` (requires `legalGround` 1..300 chars). `dismiss` and
  `restore_channel` take no ground.
- Channel roles (API strings): `owner`, `admin`, `publisher` (`role` on channel DTOs may now be `publisher`; null = none).
- Channel status: `active`, `suspended` (terminated channels are the existing soft-deleted channels, 404 for users).

## 2. Server: data (one migration `AddChannelModeration`, `--context AppDbContext`, additive)

- `ChannelReport` += `Category` (string max 10, default `terms`), `ContactEmail` (string? max 254), `GoodFaith` (bool,
  default false), `Status` (string max 10: `open` | `dismissed` | `actioned`, default `open`), `ResolvedAt`
  (DateTimeOffset?), `DecisionId` (long?, FK ModerationDecision, set null on delete). Index (Status, CreatedAt).
- `ModerationDecision` (new, append-only): `Id` long, `ChannelId` Guid (FK cascade), `PostId` Guid?, `Action` string
  max 20, `Ground` string? max 10, `Rule` string? max 3, `LegalGround` string? max 300, `Explanation` string max 2000,
  `SuspendedUntil` DateTimeOffset?, `OperatorAccountId` Guid, `ReportCount` int, `CreatedAt`. Index (ChannelId, CreatedAt).
- `Channel` += `SuspendedUntil` (DateTimeOffset?). Suspended = `SuspendedUntil > now` (no job needed).
- `ChannelAdmin.Role` gains value `publisher` (string column exists).
- Config `Moderation:OperatorAccountIds` (array of GUID) and `Moderation:OperatorHandles` (array of device
  handles, case-insensitive; the account linked to such a device is an operator), both default empty; both empty =
  every /admin route 404. `Moderation:SessionMinutes` (default 30), `Channels:MaxBotPostsPerDay` (default 20).

## 3. Server: user-facing changes

- `POST /channels/{id}/report` body `{postId?, reason, category?, contactEmail?, goodFaith?}`.
  `category` default `terms`; unknown -> 400 `invalid_category`. `contactEmail` optional, max 254, must contain `@`
  else 400 `invalid_contact`. `category = illegal` requires `goodFaith: true` else 400 `good_faith_required`.
  Response changes 204 -> **200** `{"reportId": <long>, "createdAt": ...}` (receipt, Art. 16(4)). Daily limit unchanged (429).
- `GET /channels/reports/mine` (auth, any device) -> 200 `[{"reportId", "channelId", "channelName", "channelHandle",
  "postId"|null, "category", "createdAt", "status": "open"|"dismissed"|"actioned", "resolvedAt"|null}]`, newest first,
  max 100, this device's reports only. `channelName`/`channelHandle` also for deleted channels.
- Channel DTO (`GET /channels/{idOrHandle}`, `/mine`, create/patch responses) += `"status": "active"|"suspended"`,
  `"suspendedUntil": <ts>|null`.
- `GET /channels/{id}/moderation` (owner, admin or publisher; else 403) -> 200 `[Statement]` newest first, max 50, where
  `Statement` = `{"decisionId", "action", "postId"|null, "ground"|null, "rule"|null, "legalGround"|null, "explanation",
  "suspendedUntil"|null, "basedOnReports": <bool, ReportCount > 0>, "automated": false, "createdAt"}`. `dismiss`
  decisions are NOT returned (nothing happened to the owner). Works for a suspended channel; terminated (deleted) channel
  -> the owner still gets it (owner check by account, ignore DeletedAt), others 404.
- Suspended channel (`status = suspended`): `GET /channels/{id}/posts` -> 403 `channel_suspended` for followers/others,
  allowed for owner/admin/publisher; `POST /channels/{id}/posts` -> 403 `channel_suspended` for everyone; `POST
  .../follow` -> 403 `channel_suspended`; reactions/votes -> 403 `channel_suspended`. `GET /channels/{idOrHandle}` still
  200 (profile shows the status). `/mine` still lists it.
- Admin management: `PUT /channels/{id}/admins/{deviceId}` accepts optional body `{"role": "admin"|"publisher"}` (no body
  = `admin`, as before; existing row -> role updated). Unknown role 400 `invalid_role`. Owner only (unchanged).
  `GET /channels/{id}/admins` items += `"role"`, `"isBot"`, `"handle"`, `"displayName"`|null.
- Publisher rights: may `POST .../posts`, `GET .../posts`, `DELETE .../posts/{postId}` only for posts it authored
  (`AuthorDeviceId == caller`, else 403), may upload attachments. May NOT patch the channel, manage admins, delete the
  channel. Channel DTO `role` = `publisher` for it.
- Post DTO and the `ReceiveChannelPost` hub event += `"byBot": <bool>` (author device `IsBot`).
- Bot limit: a post whose author device `IsBot` -> count of that author's posts in that channel in the last 24 h (incl.
  deleted) >= `Channels:MaxBotPostsPerDay` -> 429 `bot_post_limit`. Idempotent repeat of the same `postId` is not counted.

## 4. Server: operator API (`/admin/*`)

Auth for every route except session: operator token (section 4.1). A device token -> 403 `operator_token_required`.
An operator token on any non-`/admin` route -> 401. All routes 404 when both `Moderation:OperatorAccountIds` and `Moderation:OperatorHandles` are empty.

### 4.1 `POST /admin/session` (anonymous, rate limit "auth")

Body `{"email", "authKey", "code"?, "backupCode"?}` (authKey exactly as `POST /accounts/login`: lower-case hex SHA-256 of
the passphrase). Bad email/authKey -> 401 `invalid_credentials`. Account not in allowlist -> 403 `not_an_operator`
(only after valid credentials). MFA not enabled -> 403 `mfa_not_enabled`. Bad/missing code -> 401 `mfa_invalid_code`
(uses the existing MFA code consumption + lockout; locked -> 429 `mfa_locked`). Success -> 200
`{"token", "expiresAt", "accountId", "email"}`. Token: JWT signed like device tokens, `sub` = accountId, claims
`scope=moderation`, `amr=totp`, lifetime `Moderation:SessionMinutes`. No refresh: the web asks for a new session.

### 4.2 `GET /admin/summary` -> `{"openReports", "openSubjects", "oldestOpenAt"|null, "suspendedChannels", "decisionsLast30Days"}`

### 4.3 `GET /admin/reports?status=open|resolved|all&category=&subjectType=channel|post&before=<ts>&limit=<1..100, 50>`

Grouped by subject (channel without post, or one post). Order: oldest `firstReportedAt` first for `open`, newest
`lastReportedAt` first otherwise. Cursor `before` = `lastReportedAt` of the last item (for open: `after`, same idea;
implementer may use `cursor` opaque string instead: then name it `cursor` in request and `nextCursor` in response).
Response `{"items": [Subject], "counts": {"open", "resolved"}, "nextCursor"|null}` where
`Subject` = `{"subjectType": "channel"|"post", "channelId", "postId"|null, "status": "open"|"resolved",
"reportCount", "categories": {"illegal": n, ...}, "firstReportedAt", "lastReportedAt", "latestReason" (<=280 chars),
"channel": ChannelSummary, "post": PostSummary|null, "priorDecisions": <non-dismiss decisions on the channel>}`.
`ChannelSummary` = `{"channelId", "handle", "name", "description", "followerCount", "status", "suspendedUntil"|null,
"deleted": bool, "createdAt", "ownerHandle"}` (ownerHandle = owner device's UserHandle).
`PostSummary` = `{"postId", "kind", "body", "attachmentBlobPath"|null, "createdAt", "deleted", "byBot"}`.
A subject is `open` while any report on it is `open`.

### 4.4 `GET /admin/subjects/{channelId}?postId=<guid>` (case detail)

`{"channel": ChannelSummary, "post": PostSummary|null, "context": [PostSummary] (for a post: up to 2 before + 2 after
in the same channel; for a channel: latest 10 posts), "reports": [{"reportId", "category", "reason", "contactEmail"|null,
"goodFaith", "createdAt", "status"}], "decisions": [Decision] (all on the channel, newest first)}`. Never reporter ids.
`Decision` = Statement fields + `"operatorAccountId"`, `"reportCount"`, `"channelId"`.

### 4.5 `GET /admin/channels/{channelId}/attachments/{name}` -> the blob (any channel, also deleted/suspended), like the user route.

### 4.6 `POST /admin/decisions`

Body `{"channelId", "postId"?, "action", "ground"?, "rule"?, "legalGround"?, "explanation", "suspendDays"?}`.
Validation (400, codes): `invalid_action`; `post_required` (remove_post without postId) / `post_not_allowed` (postId with
suspend/terminate/restore); `invalid_ground`, `invalid_rule` (not K1..K10), `legal_ground_required`;
`explanation_required` (1..2000 after trim, required for every action); `invalid_suspend_days` (suspend: 1..365);
`not_suspended` (restore on an active channel) -> 409; `already_removed` (remove_post on deleted post) -> 409;
unknown channel/post -> 404. Effects:
- `dismiss`: open reports of the subject -> `dismissed`.
- `remove_post`: post soft delete + tombstone hub event (same as `DELETE /channels/{id}/posts/{postId}`); open reports of
  the post -> `actioned`.
- `suspend_channel`: `SuspendedUntil = now + days`; ALL open reports on the channel (incl. its posts) -> `actioned`.
- `terminate_channel`: existing soft delete + `ChannelDeleted` hub event; all open reports on the channel -> `actioned`.
- `restore_channel`: `SuspendedUntil = null`; reports untouched.
Writes one `ModerationDecision` (ReportCount = reports it resolved, OperatorAccountId from token). 201 -> `Decision`.

### 4.7 `GET /admin/channels?q=<handle or name fragment>&limit=<..50>` -> `[ChannelSummary]` (incl. suspended/deleted).

### 4.8 `GET /admin/decisions?before=<ts>&limit=<..100>&format=json|csv` -> `[Decision]` newest first; csv = same fields, header row, `text/csv`.

## 5. calltype_core (`ApiClient`, `channel_dtos.dart`)

- `ChannelInfo` += `String status` (default `active`), `DateTime? suspendedUntil`, `bool get isSuspended`.
- `ChannelPostDto` += `bool byBot` (default false).
- `ChannelAdminDto` += `String role` (default `admin`), `bool isBot`, `String? handle`, `String? displayName`.
- `class ModerationStatement {decisionId (int), action, postId?, ground?, rule?, legalGround?, explanation,
  suspendedUntil?, basedOnReports, createdAt}` + `ModerationStatement.fromJson`.
- `class MyReport {reportId (int), channelId, channelName, channelHandle, postId?, category, createdAt, status,
  resolvedAt?}`.
- `Future<int> reportChannel(String channelId, {String? postId, required String reason, String category = 'terms',
  String? contactEmail, bool goodFaith = false})` returns reportId (replace the existing report method's signature;
  keep a compatible call site).
- `Future<List<MyReport>> getMyReports()`, `Future<List<ModerationStatement>> getChannelModeration(String channelId)`,
  `Future<void> setChannelAdmin(String channelId, String deviceId, {required bool admin, String role = 'admin'})`.
- Error code constants: `channelSuspended = 'channel_suspended'`, `botPostLimit = 'bot_post_limit'`.

## 6. calltype_bot / hermes_bridge

- `CallTypeBot.postToChannel(String channel, String text) -> Future<String postId>`: `channel` = channel id or `CH-` handle
  (resolved via `GET /channels/{idOrHandle}`), kind `text`, client-generated postId. Throws `BotSendException` with the
  server code on 403/429.
- Hermes bridge `/send`: `to` may be `channel:<CH-handle or id>` -> `postToChannel`; 202 sent, 403 not a
  publisher/admin/owner or suspended, 429 bot limit (new status), 400 bad target. Not counted as a group bot turn.
  README documents the newsletter recipe (Hermes cron -> curl `/send`).

## 7. App (`src/client/calltype`)

- Report dialog: category (3 choices), reason, for `illegal` a good-faith checkbox (required) and an optional e-mail
  field; link "Channel rules" (locale cs -> `channels-cs.html`, else `channels-en.html`); on success a snackbar with the
  report number.
- "Reports I filed" screen (reachable from the channels/updates screen menu): list of `MyReport` with status text
  (pending / no action / action taken).
- Channel profile: suspended banner for everyone (with date); for owner/admin/publisher a "Moderation" section listing
  statements (action, rule with link to the rules anchor, explanation, date, redress text: "Disagree? Write to
  martin@zcloud.cz within 6 months.").
- Feed: `byBot` posts show a BOT label; 403 `channel_suspended` shows the suspended state instead of an error.
- Admins screen: role per member (admin / publisher), add by handle (lookup `GET /devices/by-handle/{handle}`), BOT badge.
- Channel create screen: link to the rules ("By creating a channel you agree to the channel rules").
- All strings through l10n in every locale. The app must NOT touch `web/staticwebapp.config.json` or `web/legal/`.

## 8. Admin web (`src/client/jay_admin`, new Flutter package)

- Flutter web only, `--base-href /admin/`, hash URL strategy. Own small HTTP client (no calltype_core dependency
  needed). API base URL via `--dart-define=CALLTYPE_API_BASE_URL` like the app. Locales cs + en (cs default if the
  browser prefers cs).
- Screens per design: login (e-mail, passphrase, TOTP or backup code; token in memory only, re-login after expiry),
  overview (summary), queue (tabs open/resolved/all with counts, filters, subject rows, keyboard j/k/Enter), case detail
  (two columns, images blurred until click, decision panel with action, ground, rule picker showing rule titles,
  explanation, preview of the owner's statement, confirm; terminate requires typing the channel handle), channels search,
  audit log with CSV export.
- Deployment: `deploy.yml` web job builds jay_admin and copies it to `build/web/admin` before the artifact upload;
  `web/staticwebapp.config.json` excludes `/admin/*` from the app's navigation fallback, serves `/admin/index.html`
  for `/admin` and adds headers on `/admin/*`: `X-Frame-Options: DENY`, `X-Robots-Tag: noindex`,
  `Cache-Control: no-store` for `/admin/index.html`. `ci.yml` analyzes and tests jay_admin.
