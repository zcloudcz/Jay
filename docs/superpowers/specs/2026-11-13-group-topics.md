# Group topics: a topic per group, admins, bots that read along (contract)

Status: spec on `feat/group-topics` (from `origin/master` 0a74190). Not released.

A group becomes a focused conversation: it has a topic (a short brief, also a prompt for the
bots), the group admins manage it, and the bots of the group can use it, read the whole
conversation and answer without an @mention when the admins switch that on. Several topics with
the same bots = several groups with the same members (T6). Analysis:
`~/.hermes/cache/scratch/group-topics/analysis.md` (Czech). Owner decisions of 2026-11-13 are
rows 1-3 below.

## Decisions

| # | Topic | Decision |
|---|---|---|
| 1 | Who sets the topic | Only group ADMINS. Admins may promote other members to admin and demote admins; the last admin cannot be demoted (409 `last_admin`, same rule as removing). The creator is only the first admin. The server enforces both (rows 6, 7). |
| 2 | T3 / T4 defaults | "Bots read everything" (T3) and "Reply without mention" (T4) are per-group switches, OFF by default, changed by admins only. They live in the existing bot-talk setting (`PUT /groups/{id}/bot-talk`), so bots learn them exactly like the bot-talk mode today (`GET /groups/{id}`, `GroupChanged` hint). |
| 3 | Scope | T1-T6 in one change and one release. |
| 4 | Topic content | Plain text, trimmed, 0..4000 characters (Dart `String.length`); empty = no topic (cleared). End to end encrypted: the server never sees it. Members (and member bots) see it; it is not secret from members. |
| 5 | Transport | A control message `type: "group-topic"` in the group fan-out to every member device (bots and own other devices included), never a bubble, never unread, never a push. Wire shape in "Wire shapes". |
| 6 | Server role in the topic | The server stores topic METADATA only: `version` (server-assigned, strictly increasing), `updatedBy` (the admin's device = identity, companions cannot manage groups) and `updatedAt`. `PUT /groups/{id}/topic` (admin only) records a new version; the admin's client then sends the content with that version. A receiver accepts a topic only when the server's CURRENT record names exactly that version and that sender identity. So a non-admin cannot set a topic (the server refuses to record it, every receiver refuses unrecorded content), and a stale or forged version is dropped. |
| 7 | Roles endpoint | `PUT /groups/{id}/members/{deviceId}/role` `{"role":"admin"\|"member"}`, admin only. Bots cannot become admins (400 `bot_cannot_be_admin`): an admin can remove members and change bot settings, which a bot must never do on its own; the auditor is immutable (409 `auditor_immutable`). |
| 8 | Ordering | Last writer wins by `version` (server-assigned, so no client clock skew). A receiver applies a version only when it is greater than the stored one; an equal version is a no-op (idempotent resend). |
| 9 | Why no server-side ciphertext copy | DEVIATION from the brief ("encrypted copy on the server like NameEncrypted"): Jay groups have no shared group key (pairwise fan-out, Sender Keys are pending; `Group.NameEncrypted` exists in the schema but nothing writes it). A blob stored on the server could not be decrypted by a member who joins later, so it would add nothing. New members get the topic like this instead: the app has no "add member" UI (members are set at creation), and at creation (incl. T6) the creator sends the topic right after `POST /groups`, so every first member gets it; any later code path that adds a member must resend the current topic (same version, row 8 makes it a no-op for the others). The server record (row 6) lets a client see that a topic exists that it does not have yet. |
| 10 | Unknown group | A valid `group-topic` for a group the receiver does not know yet creates the group conversation (type `group`, title from `groupName`, `unreadCount` unchanged), exactly like a first text message would. WHY: T6 and "create with topic" send the topic before any text, and the members should see the new topic group at once. |
| 11 | Business groups | No topics in business (organization) groups in v1: the server answers 409 `business_group` on `PUT /groups/{id}/topic`, the app hides the UI, receivers drop a topic for a business conversation. `jay_archiver` still accepts the type as metadata-only text (K01). |
| 12 | App: where the topic shows | One line under the group name in the chat header (ellipsis), tap opens Group info. Group info (new screen, `/chats/:id/info`, also from the group menu): name, full topic (selectable), "Edit topic" for admins, member list with role labels. |
| 13 | App: admin actions | In Group info each member row has a menu "Make admin" / "Remove admin", shown only when the viewer is an admin, never for bots, the auditor or (for "Remove admin") when the target is the only admin. Errors (`last_admin`, network) show a snack bar; the list reloads from the server after every change and on `GroupChanged`. |
| 14 | App: setting the topic | Group create screen: optional multiline "Topic" field (counter, 4000 max). Group info: "Edit topic" dialog (admins). Flow: `PUT /groups/{id}/topic` -> send `group-topic` with the returned version -> store locally. On PUT failure nothing is sent (403 "only admins", 404 "not supported by the server yet"). After a successful PUT the topic is stored locally at once (the server already names this identity as the author of that version). On a transient send failure the transient control row (`type: group-topic`, in `controlTypes`) stays and the app-wide automatic resend retries it (it is not restored like a reaction: the version is recorded, so a later retry with the same version is still accepted); a permanent failure drops the row and shows an error. App code: `GroupTopicService` (app-wide, also used by the create screen and Group info), receiver `applyGroupTopic`, storage `group_topic_store.dart`. |
| 15 | App: T3/T4 switches | Two switches in the existing bot-talk screen ("Bots read everything", "Reply without mention"), admins only (the screen is already admin-gated), with a one-line explanation each. Independent from the bot-talk mode. |
| 16 | App: T6 | Group menu "New topic with these members": the create screen opens with every current member pre-selected (bots included; minus self and the auditor; hidden in business groups and on companion devices, which cannot create groups: 403 `companion_cannot_manage_groups`), asks for name and topic. Members that are not local contacts are listed by their server profile name. |
| 17 | App storage | Local topic in the drift `backup_state` key-value table, key `group-topic:<conversationId>`, value JSON `{"topic","version","setBy"}` (skill rule: no `schemaVersion` bump, no collision with unmerged branches). Part of the backup and history transfer as additive `backup_state` rows (like participant colors), imported leniently (bad row skipped). Wipe/reset (`DeviceService._wipe`, `resetForLinking`) delete the `group-topic:` rows explicitly: they clear only listed `backup_state` prefixes, not the whole table (the earlier "already clear" assumption was wrong). Deleting a chat keeps its topic row (the user may still be a member; the topic is group state, not history). Backup JSON key `groupTopics: [{conversationId, topic, version, setBy}]`; import keeps the higher version (a history transfer can bring a newer one). |
| 18 | T2: bots use the topic | `calltype_bot` validates and stores the topic per group (bot store) and exposes it on every group `BotMessage` (`groupTopic`, `groupTopicVersion`). `llm_bridge`: appended to the system prompt for that group, framed as "set by the group admins". `hermes_bridge`: a `[Group topic: ...]` block in front of the message on the first turn of a conversation in this bridge run and whenever the version differs from the last one sent (remembered in the bot store, so a restart re-sends once at most). `a2a_bridge`: the topic as a leading text part (same first-turn/changed rule as hermes) and in message metadata `jayGroupTopic`. Built: runtime `BotMessage.groupTopic` (null when none or cleared), `groupTopicVersion` (also for a cleared topic), `CallTypeBot.groupTopic(groupId)` -> `BotGroupTopic {topic, version, setBy}`, `backupState` row `group-topic:<group id>`; hermes keeps the last sent version via `readBridgeState`/`writeBridgeState` (`backupState` `bridge:` rows, no content), a2a in its state file (additive `topics` map). A cleared topic is told once (`[Group topic cleared by the group admins]`) only when the backend heard one before. |
| 19 | T3: bots read everything | With `botsReadAll` on, a group message that does not start a turn (not addressed, or from a sender the bridge does not admit for turns) is handed to the bridge as CONTEXT: never answered, no typing, no ack reaction, no actions/commands, no rescue. `llm_bridge` adds it to the conversation history as a user turn labelled with the sender name; `hermes_bridge` and `a2a_bridge` buffer it (per conversation, newest 50 entries / 8000 characters, in memory) and send it as a `[Meanwhile in the group: ...]` block in front of the next addressed turn. Messages of other bots count as context too (that is the point); context never triggers anything, so it cannot loop. Built: `onContext(handler)` + `onMessage(servesGroup:)` in `calltype_bot`; servesGroup = an owner of the bot is a member (all three bridges). A bot message the bridge's bot-talk rules drop after decryption becomes context too. Because T3/T4 need the group settings, the runtime now decides about every unaddressed group message in the conversation queue after one cached `GET /groups/{id}` (before: acked at once without a lookup); with both flags off the outcome is the same ack. Shared helpers `GroupContextBuffer` / `GroupTopicAnnouncer` live in `calltype_bot` (a2a's runtime-free `bridge.dart` keeps a copy of the announcer rule). |
| 20 | T4: reply without mention | With `replyWithoutMention` on, a message from a HUMAN member that the bridge admits for turns counts as addressed. Messages from bots still need an explicit mention or reply AND pass the bot-talk rules (mode, max turns, pause), unchanged. So T4 alone can never make bots answer each other; with several bots each answers the human once. |
| 21 | Admission (security) | Unchanged: the server's inbound filter (bot policy `owners`) and each bridge's group rule (an owner of the bot is a member, resp. admin for hermes bot talk). New: a group message from a sender the bridge does not admit for turns is still DECRYPTED when the bridge says it serves that group (an owner is a member); it can then only update the topic (row 6 check) or become context (row 19). It never starts a turn. Rescue actions stay owner 1:1 only. Text from others is context, framed as such in prompts, never instructions. |
| 22 | T5: llm_bridge long memory | When a conversation's history exceeds `LLM_HISTORY_MESSAGES` (default 20), the older part is folded into ONE summary by the same provider (a separate summarization call) and the store keeps summary + the newest `LLM_HISTORY_KEEP` messages (default 10). The summary (max 4000 characters) is persisted per conversation in the encrypted history store and given to the model as a framed system-prompt section. It runs after the reply was sent, in the conversation queue. A failed or empty summary falls back to plain truncation (today's behaviour). `LLM_HISTORY_SUMMARY=0` turns it off. `/new` clears the summary too. Built: an explicit `LLM_HISTORY_KEEP` must be below `LLM_HISTORY_MESSAGES` (start refused otherwise); unset, it defaults to 10, or to half of a `LLM_HISTORY_MESSAGES` of 20 or less, so older configs (e.g. 8 messages) still start. Without history (`LLM_HISTORY_MESSAGES=0`) there is no summary. Context lines (T3) count against the cap and are folded like other messages. |
| 23 | Old clients | See "Compatibility". New JSON fields are optional everywhere; unknown fields are ignored. |

## Server

Migration `AddGroupTopicsAndBotReading` (additive, AppDbContext): `Groups` gets
`TopicVersion bigint NULL`, `TopicUpdatedBy uuid NULL`, `TopicUpdatedAt timestamptz NULL`, and the
owned `BotTalk` gets `BotTalkBotsReadAll boolean NOT NULL DEFAULT false` and
`BotTalkReplyWithoutMention boolean NOT NULL DEFAULT false` (the existing `BotTalk*` owned-type
column naming). Roles need no schema change. Migration file
`20261113144503_AddGroupTopicsAndBotReading`.

| # | Endpoint | Contract |
|---|---|---|
| S1 | `PUT /groups/{id}/members/{deviceId}/role` | Body `{"role":"admin"\|"member"}`. Gate = AddMember's (`Authorize(admin: true)` on the RAW caller device): 404 unknown group, 403 non-member / non-admin / companion. Then, in this order: 400 `invalid_role` (anything else, also missing or upper case); 404 `not_a_member` target not in the group; 409 `auditor_immutable`; 400 `bot_cannot_be_admin` (promote a bot; keeping a bot `member` is 200); same role = 200 (idempotent); 409 `last_admin` (demote the only admin, also self). Errors are `{error: <code>, code: <code>}` like RemoveMember's `last_admin`. The check and write run under a row lock on the group (caller re-checked under the lock), so two admins demoting each other at once leave one admin. 200 `{deviceId, role}`. Sends `GroupChanged`. Rate policy `api`. |
| S2 | `PUT /groups/{id}/topic` | Body `{}` (content never goes to the server; unknown fields ignored). Admin gate as S1. 409 `business_group` for an organization group. Stores `version = max(stored + 1, now in Unix ms)`, `updatedBy = caller`, `updatedAt = now` in one atomic `UPDATE ... RETURNING`, so concurrent admins get distinct versions and each answer names its own caller. 200 `{version, updatedBy, updatedAt}` (`updatedBy` lower-case GUID string). Sends `GroupChanged`. Rate policy `api`. |
| S3 | `GET /groups/{id}` | Additive `topic`: `{version, updatedBy, updatedAt}` or `null` when never set. `botTalk` gets `botsReadAll` and `replyWithoutMention` (booleans). |
| S4 | `PUT /groups/{id}/bot-talk` | Additive optional `botsReadAll`, `replyWithoutMention` (bool or omitted/null = keep the stored value, so an old app flipping the mode does not reset them). Response carries both. |

## Wire shapes

Same outer payload as every group message (inside the E2E envelope):
`{v: 1, id, type, body, groupId, groupName, createdAt}`; `body` stays a STRING.

```json
{
  "v": 1,
  "id": "<new message id>",
  "type": "group-topic",
  "body": "{\"topic\":\"Plan the Brno trip. Bots: keep answers short.\",\"version\":1763031330123}",
  "groupId": "<group id>",
  "groupName": "Brno trip",
  "createdAt": "2026-11-13T10:15:30.123Z"
}
```

- Codec: `calltype_protocol/lib/messaging/group_topic.dart` (`groupTopicType`,
  `maxGroupTopicLength = 4000`, `GroupTopicPayload {topic, version}`), re-exported at
  `calltype_core/lib/messaging/group_topic.dart`. `encode()` trims and throws `ArgumentError` for
  > 4000 characters or `version <= 0`; `decode()` returns null (never throws) for anything else
  (non-string body, > 16 KiB body, bad JSON, missing/wrong types, too long, version not a positive
  integer).
- Receiver (app and `calltype_bot`), in order; every refusal is acked and dropped:
  1. `groupId` present (a 1:1 `group-topic` is dropped), body decodes.
  2. Not a business conversation (app).
  3. Fresh `GET /groups/{id}` (never the cache): `topic.version == version` and
     `lower(topic.updatedBy) == sender identity` (the authenticated sender, never a body field).
  4. `version >` stored version, else no-op.
  5. Store `{topic, version, setBy}`; app: create the conversation if unknown (row 10).
  A network error in step 3 is transient: the app leaves the message queued (not acked, like any
  other transient inbox error); a bot logs and drops it (bots handle at most once; the next change
  re-sends).
- Sender: own other devices receive the group fan-out copy and apply it under the own identity.

## Compatibility

| Peer | Behaviour |
|---|---|
| Old app receives `group-topic` | Throws "Unsupported message type" before storing; the message stays queued for it until the 30-day TTL (same accepted cost as reactions/pins at their launch). It never shows the topic. |
| Old bot runtime | Acks and ignores unknown types (calltype_bot already does). |
| Old `jay_archiver` | Never gets one: topics are refused for business groups (row 11). |
| Old app + new server | Never calls the new endpoints; its `PUT /bot-talk` omits the new fields, which keeps them (S4). |
| New app + old server | `PUT /topic` and `/role` answer 404: the app shows "not supported by the server yet" and sends nothing. `GET /groups/{id}` without `topic` = no topic; without the new bot-talk fields = both off. |
| Old bots in a group with T3/T4 on | They keep answering only when addressed and never read context (no harm). |

## Limits (v1)

- A member added later through the raw API (the app has no add-member UI) or a device restored from
  a backup older than the topic gets the topic only with the next change (row 9).
- `hermes_bridge` / `a2a_bridge` context buffers live in memory: a bridge restart loses unanswered
  context. `llm_bridge` keeps context in its persisted history.
- Bots cannot be admins (row 7).
- No threads inside one group (analysis: a group IS the topic).

## Acceptance (automated, must pass)

1. Protocol: `GroupTopicPayload` encode/decode valid, empty, 4000/4001 characters, bad version, bad JSON, wrong types.
2. Server S1: promote, demote, idempotent, last admin 409, auditor 409, bot 400, non-admin 403, companion 403, unknown member 404, invalid role 400, `GroupChanged` sent.
3. Server S2/S3: admin records versions strictly increasing; non-admin 403; business 409; `GET` shows the record; never-set = null.
4. Server S4: new flags stored, returned, omitted = kept, default false.
5. App inbox: valid topic applied; non-recorded version, other sender, 1:1, business, older/equal version dropped and acked; unknown group creates the conversation without unread; redelivery acked.
6. App: header line, Group info (topic, roles), admin-only role menu and edit, bot-talk switches, create with topic, T6 pre-selection; backup round trip of the topic row; all strings in 19 ARB files.
7. `calltype_bot`: topic validated/stored/exposed; T4 addressed rule (human yes, bot no); T3 context handler gets unaddressed and non-admitted group messages only when `botsReadAll` and the group is served; context never acked with a reaction or answered.
8. `llm_bridge`: topic in system prompt; context in history; summary when over the limit, failure = truncation, `/new` clears it, `LLM_HISTORY_SUMMARY=0` off.
9. `hermes_bridge`: topic block on first turn and on change only; context block in front of the next turn, capped.
10. `a2a_bridge`: topic part + metadata; context block.
11. `jay_archiver`: `group-topic` archived as metadata-only text, malformed rejected.
12. Docker builds of the three bridge images.

Manual checks: `docs/acceptance/group-topics.md` (NOT_RUN until tested by hand).
