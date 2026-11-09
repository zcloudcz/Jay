# Delete chats and contacts, leave groups

Status: approved (owner 2026-11-09, Discord): after removing a test bot "Rád bych [smazal chat a kontakt], ale nemáme asi mazání chatů/kontaktů." Confirmed on master: no UI to delete a conversation or a contact; contact sync already carries removals (`contact-removed:` tombstones in `contact_sync.dart`) but nothing in the app creates one; groups have only creation in the app (`group_controller.dart`: "leave ... would also live here"), the server has `DELETE /groups/{id}/members/{deviceId}`.

## Decisions

| # | Decision |
|---|---|
| D1 | Delete chat (1:1 or group) from the chat list (long press / context menu / swipe on mobile, right-click and the overflow menu on web/desktop) and from the chat's app bar menu. Confirmation dialog. Deletes on THIS identity only: the conversation row, its messages, attachments/media cache, pins, poll votes, reactions, outbox rows and read/resend state of that conversation. The other side keeps its copy (say so in the dialog). |
| D2 | Own devices: a deleted chat is also deleted on my other own devices via an own-device control message `chat-deleted` (Pattern A, like `read-state`): `{"v":1,"conversationId":"<id>","deletedAt":<ms>}`; the receiver deletes only messages with `createdAt <= deletedAt` (a message that arrived later survives, so nothing new is lost), accepted only from own devices. Codec in calltype_protocol like `read_state.dart`. |
| D3 | A new message in a deleted 1:1 chat recreates the conversation as today (inbox path). A deleted group chat: deleting does NOT leave the group; new group messages bring it back. The dialog for a group offers "Delete chat" and "Leave group and delete" (D5). |
| D4 | Delete contact: in the contact list (context menu) and in the 1:1 chat menu. Confirmation. Removes the contact row and writes the existing `contact-removed:` tombstone so contact sync removes it on my other devices (reuse the existing sync path; add the local-change hook if missing). Option checkbox "Also delete the chat" (default on). Contact removal does not block the person; blocking stays a separate feature (out of scope here). |
| D5 | Leave group: group detail -> "Leave group" (+ the D3 dialog). Calls `DELETE /groups/{id}/members/{myDeviceId}` for each of my own devices that is a member (check server rules: a member may remove itself; if not allowed, add a minimal server change with tests and document it in AGENTS.md + spec). The last admin leaving: follow the server's rule; if the server refuses, show a clear message ("make someone else admin first"). After leaving, delete the chat locally (D1/D2). |
| D6 | Business conversations: deletion is local only and allowed (the server-side audit archive is untouched); state it in the dialog. Leaving a business group follows the existing business policy; if the server forbids it, hide the action. |
| D7 | Bots: a 1:1 chat with a bot whose identity is gone (removed by `jay-new-bot --remove`) is deletable like any other chat. |
| D8 | All new strings in the 19 ARB files. Backup: deleted chats are simply absent from a new backup; restoring an OLDER backup may bring them back (documented limit). |

## Server change (D5)
Checked on 2026-11-09: `DELETE /groups/{id}/members/{deviceId}` was admin only, so an ordinary member could not leave, and a companion is never a member itself (membership lives on the primary). Minimal change in `RemoveMember`:
- Leaving = the target device belongs to the caller's own identity (`PrimaryOf(caller) == PrimaryOf(target)`). It needs no admin role; the target must be a member (else 403 like any outsider, 404 for an unknown group). A companion leaves for its identity by removing its primary.
- Unchanged: removing anybody else is admin only; the auditor can never be removed (409 `auditor_immutable`), also not by itself; the last admin cannot be removed (409), also not by itself. That 409 now carries `code: "last_admin"` (additive) so the app can show a clear message. There is no endpoint to make another member admin, so the creator of a group cannot leave it while it is the only admin (see Limits).
- Business groups: a member may leave like an admin may remove it (D6, the archive is untouched).
- Tests: `GroupEndpointsTests` (member leaves but cannot remove others, companion leaves via its primary, last admin `code`, unknown group) and `BusinessGroupEndpointsTests` (member leaves a business group, the auditor cannot). AGENTS.md endpoint table updated.

## Tests
Codec test for `chat-deleted`; controller tests: delete removes all rows of that conversation only (other conversations untouched, incl. media cache files via a fake), own-device message sent when companions exist and applied on the other device only up to `deletedAt`, foreign sender rejected; contact delete writes the tombstone and syncs; leave group calls the endpoint for own member devices and deletes locally; widget tests for the menus and dialogs (mobile and wide layout), business dialog text, l10n guard. Server tests only if D5 needed a server change.

## Limits
- Deleting is not "delete for everyone".
- Restoring an older backup can bring a deleted chat back.
- The only admin of a group (usually its creator) cannot leave it: the server keeps at least one admin and there is no way yet to make another member admin. The app says so and offers to delete the chat only.
