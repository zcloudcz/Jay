# Delete chats and contacts, leave groups

Status: implemented on branch `feat/delete-chats` (not released). Approved (owner 2026-11-09, Discord): after removing a test bot "Rád bych [smazal chat a kontakt], ale nemáme asi mazání chatů/kontaktů." Confirmed on master: no UI to delete a conversation or a contact; contact sync already carries removals (`contact-removed:` tombstones in `contact_sync.dart`) but nothing in the app creates one; groups have only creation in the app (`group_controller.dart`: "leave ... would also live here"), the server has `DELETE /groups/{id}/members/{deviceId}`.

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

## Implementation notes (2026-11-09, as built)
- Wire: `chat-deleted` is an own-device control message (Pattern A, like `read-state`): `{"v":1,"conversationId":"<id>","deletedAt":<ms>}`, codec `calltype_protocol/lib/messaging/chat_deleted.dart` (re-exported by `calltype_core/messaging/chat_deleted.dart`), documented in `docs/protocol/payloads.md`. Sent through `OwnDeviceSender` (own outbox, retried on reconnect), only when the identity has other devices. The inbox accepts it only from an own device in a direct delivery; a foreign sender's copy is acked and dropped; an unknown conversation is acked and ignored. Never a message row, never unread; it cancels the conversation's notifications like a read elsewhere.
- Local deletion (`lib/features/chat/chat_deletion.dart`, `ChatDeletionService`): messages, their reactions, pins, poll votes, `outbox:`/`extra:`/`mediaup:`/`sendfail:` state, then the conversation row with its `draft:` and `read-upto:` keys when no message is left (otherwise the unread count is capped at the incoming messages left). Media files go after the commit unless another message still references the same media id (forwarded copy). Runs in the inbox processing queue so an arriving message cannot interleave.
- Tombstone `chat-deleted:<conversationId>` = ms in `backup_state` (added to `DeviceService._wipe`/`resetForLinking`): a contact-sync SNAPSHOT carries conversation headers without a time, so it must not recreate an empty deleted chat on a device that runs it later. The inbox ignores the tombstone, so a new message still recreates the chat (D3).
- Contact delete (`ContactsController.deleteContact`): deletes the row, writes the existing `contact-removed:<deviceId>` tombstone and sends the existing `contact-sync` `remove` op via the new `ContactSyncService.contactRemoved`. "Also delete the chat" (default on) then runs the chat deletion.
- Leave group (`ChatDeletionService.leaveGroup`): `GET /groups/{id}/members`, then `DELETE /groups/{id}/members/{deviceId}` for every member that is one of this identity's devices (in practice the primary, also when a companion leaves). 403/404 on the member list = no member any more: the chat is just deleted. 404/403 on the delete = already gone. 409 `code: last_admin` = clear message, nothing deleted. Any other error = "could not leave", nothing deleted. After leaving: chat deletion (D1/D2).
- UI: chat list long press and right click open an action sheet (mute, delete chat, leave group for groups, delete contact for a 1:1 contact); phones also swipe left to delete; wide layouts (>= 600 px) add an overflow button per row. The chat app bar menu has "Delete chat" + "Delete contact" (1:1) or "Delete chat" + "Leave group" (group). Business chats show "The organization's archive is not affected." in the dialogs.
- Deviations from the decisions above, and why:
  - D5 "group detail -> Leave group": there is no group detail screen in the app, so "Leave group" sits in the group chat's app bar menu (next to Bot talk) and in the chat list action sheet.
  - D1 long press: the long press used to open the mute dialog directly; it now opens the action sheet whose first entry is the same mute dialog (one more tap to mute, but one place for every chat action).
  - D5 last admin: the server keeps its rule, but there is no way to make another member admin, so the message says the user is the only admin and can still delete the chat (instead of "make someone else admin first", which the app cannot do).
  - D2 granularity: drift stores `createdAt` in whole seconds, so on the receiving device a message created in the same second as the deletion counts as older and is deleted too.
  - Companions: business conversations stay read-only on a companion, but deleting such a chat locally (and leaving, which removes the primary) is allowed there, like on the primary.

## Compatibility
| Peer | Behaviour |
|---|---|
| Own device with an older app | Throws "Unsupported message type" before storing: `chat-deleted` stays queued on the server until the 30-day TTL; that device keeps the chat until it updates (then the queued message deletes it). |
| Other participants | Not involved: no message goes to them. The server sends the usual `GroupChanged` hint after a leave. |
| Bots (`calltype_bot`, `jay_archiver`) | Never receive `chat-deleted` (it goes only to the sender's own devices; the auditor is never an own device). No bot change. |
| Older server | `DELETE /groups/{id}/members/{own device}` by a non-admin answers 403: the app shows "Could not leave the group" and deletes nothing. |

## Tests
As built: `calltype_protocol/test/messaging/chat_deleted_test.dart` (codec), `calltype/test/features/chat/delete_chats_flow_test.dart` (phone + web + contact on the fake multi-device server: delete with all dependent rows and state, other chat untouched, Bob keeps his copy, recreate by new message, `deletedAt` keeps later messages and caps unread, unknown chat, foreign sender, no companions, media files incl. a forwarded copy, snapshot does not resurrect, contact delete syncs, leave group: companion via primary, last admin, already left, server error, delete does not leave) and `delete_chats_widgets_test.dart` (narrow and wide chat list, swipe, group/business dialogs, last admin message, contact delete from list and chat list, chat app bar menus). Planned:
Codec test for `chat-deleted`; controller tests: delete removes all rows of that conversation only (other conversations untouched, incl. media cache files via a fake), own-device message sent when companions exist and applied on the other device only up to `deletedAt`, foreign sender rejected; contact delete writes the tombstone and syncs; leave group calls the endpoint for own member devices and deletes locally; widget tests for the menus and dialogs (mobile and wide layout), business dialog text, l10n guard. Server tests only if D5 needed a server change.

## Limits
- Deleting is not "delete for everyone".
- Restoring an older backup can bring a deleted chat back.
- The only admin of a group (usually its creator) cannot leave it: the server keeps at least one admin and there is no way yet to make another member admin. The app says so and offers to delete the chat only.
