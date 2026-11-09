# Automatic resend of failed messages and read-state sync between own devices

Status: approved (owner feedback 2026-11-09, Discord):
1. "při nezdařeném odeslání zprávy musí user kliknout na Odeslat znovu, toto by se mělo hlídat a zkoušet samo"
2. "u synchronizovaného zařízení se zobrazují notifikace o doručených zprávách i když byly přečteny na jiném zařízení. Šlo by zařídit i sync přečtených zpráv?"

Part 2 is the read-state item of multi-device spec 3 (`2026-10-13-multi-device-sync-design.md`, roadmap). Delete-for-me sync and ringing on all devices stay out of scope.

## Part 1: automatic resend

### Today
`ChatController` (one per OPEN chat, created in `router.dart`) sends through `retryMessage` -> `_sendQueued`; any exception sets the row to `failed` and the bubble shows "Send again" (`chat_screen.dart`). Nothing retries by itself, and a message that failed in a chat the user left is never retried.

### Decisions

| # | Decision |
|---|---|
| R1 | An app-wide resend service (not tied to an open chat) retries own messages with status `failed` (and `sending` rows left over from a killed app, older than 2 minutes) in every conversation. |
| R2 | Triggers: hub connection becomes connected (reconnect), app returns to the foreground, and a backoff timer per message: 5 s, 15 s, 1 min, 5 min, then every 15 min. Only while the app runs; no background work. |
| R3 | Give up automatically after 24 h from the message's `createdAt`: the row stays `failed` with the manual "Send again" button (as today). Manual send again always works and resets the backoff. |
| R4 | Permanent failures are NOT retried automatically: `audit_recipient_missing`, `auditor_unavailable`, `business_conversation_required`, a cancelled media upload (`MediaCancelled`), a conversation that no longer exists or the user left, and any error the code already classifies as not recoverable. They are remembered per message (`backup_state` key `sendfail:<messageId>` = reason) and show the manual button like today. Everything else (network, hub not connected, timeouts, 5xx, device_list_stale after the existing repair rounds) is transient. |
| R5 | No duplicates: retries go through the same `MessageProcessingQueue` and the same stored outbox (`outbox:<id>`, byte-identical envelopes) as the manual retry; a row that is `sent` or newer is never resent; two triggers at once resend once. The receiver side already dedupes by message id (verify and cover with a test: same envelope delivered twice = one bubble). |
| R6 | Media: a failed media message retries its upload the same way the manual retry does (`_prepareMedia`), with the same backoff. |
| R7 | Control rows (reactions, pins, votes, edit, delete, own-device sync) that use the outbox are covered by the same service, with the same rules. |
| R8 | UI: while an automatic retry is pending the bubble shows the existing "sending" state (clock) instead of the red failed state; after giving up (R3) or a permanent failure (R4) it shows the failed state and the manual button as today. No new strings unless needed for a "will retry" hint; if added, all 19 ARB files. |
| R9 | Implementation constraint: reuse the existing send path; do not fork the encryption/fan-out code. If `ChatController` cannot be driven headless, extract the send/retry core into a service both use. |

### As built (part 1)

- R9: `ChatController` could not be driven headless (it marks its conversation read and loads members on creation), so the send core moved into `MessageSender` (`lib/features/chat/message_sender.dart`): media upload, outbox, fan-out with stale repair, business fallback. `ChatController.retryMessage` and the app-wide `ResendService` (`resend_service.dart`, created in `main.dart`) both call it. Nothing of the encryption or fan-out code was forked.
- R1/R2: `ResendService.trigger()` runs on every transition of the hub to connected (also the first connect after start) and on app resume; each message also has its own timer step (5 s, 15 s, 1 min, 5 min, then every 15 min, counted per message from the last failure). A timer step is skipped while the hub is disconnected (it would fail at once); the reconnect trigger follows.
- R4, deviation: `auditor_unavailable` is TRANSIENT, not permanent. The existing code and its comment classify it as "an availability problem the user can just retry" (the hub fails closed until the auditor is back), which is exactly what an automatic resend is for. Permanent (stored as `sendfail:<id>` = reason): `audit_recipient_missing`, `business_conversation_required`, `not_a_business_member`, `fanout_too_many_devices`, "Sender and recipients must be group members" (left the group), "Group message exceeds maximum member count", "Invalid encrypted payload ...", "Conversation must be a device or group UUID", a cancelled upload, an HTTP 4xx other than 401/408/429 (e.g. member list of a group the user left), and the cases the old code threw as `StateError`: conversation missing, business conversation on a companion, no recipients, media not uploaded, invalid poll, invalid media draft. Everything else is transient. A later transient failure of a manual retry removes the marker again.
- R3: at 24 h after `createdAt` the service writes `sendfail:<id>` = `expired` (the bubble then flips to the failed state). A manual retry still runs; if it fails transiently after 24 h nothing retries it again.
- R5: `OutboxRegistry` (per database, like `MessageProcessingQueue`) refuses a second attempt of an id that is in flight, and the queue job still skips a row that is not `failed`/`sending`. Covered: two triggers at once = one hub call; a duplicated envelope = one bubble on the receiver.
- R7: transient control rows (edit, delete, reaction, pin, vote) are owned by the flow that created them (it restores or finishes the local state and drops the row whatever happened); the flow holds the id in `OutboxRegistry` until then and the service never touches a held row. The service only takes over ORPHAN control rows (app killed mid-flow, older than 2 minutes): it sends them, then finishes what the flow would have done (`delete`: tombstone; `edit`: new body; reaction/pin/vote were applied before the send) and drops the row; on a permanent failure or after 24 h it drops the row (a reaction/pin/vote then stays applied locally only). Own-device sync messages (`contact-sync`, `read-state`, history transfer) do not use message rows; they stay on their own `ownsync:` outbox that `OwnDeviceSender.resendPending` retries on every reconnect (unchanged).
- R8: the bubble of a failed message that is still inside the window and not permanent shows the existing "Sending, retry" state (`chatStatusSendingRetry`), tapping it is a manual retry; no new strings.
- Business call reports (`call-event`, written by `CallEventSender`) are own rows too and are covered by the same rules.

## Part 2: read-state sync between own devices

### Today
Read state is local only: opening a chat sets `conversations.unread_count = 0` (`ChatController._markRead`). Local notifications are shown by `NotificationService.onMessage` on every device that decrypts the message, and are not cleared when the chat was read on another own device. Own devices sync messages (fan-out) and contacts (`contact-sync`).

### Decisions

| # | Decision |
|---|---|
| S1 | New own-device control message `read-state` (Pattern A in the skill's chat-message-types reference, "own-device sync to self"): body `{"v":1,"conversationId":"<id>","readUpTo":<ms>}`, where `readUpTo` = `createdAt` in ms of the newest message the user has seen in that conversation. Codec in `calltype_protocol/lib/messaging/read_state.dart` (encode throws on invalid, decode returns null), re-exported like the other codecs. |
| S2 | Sent when a conversation becomes read on this device (unread goes to 0 while the chat is open in the foreground, or the user marks it read), at most once per conversation per 3 s, only if `readUpTo` grew, only when this identity has other own devices (no companions = do not send; the hub refuses an empty set). Sent via `SendReliableDirectFanout` to the own primary like `contact-sync`. |
| S3 | Accepted only when `DeviceDirectory.identityOf(sender) == selfIdentityId`. Unknown conversation: ignored (acked). Business conversations: allowed (no content, only a timestamp) unless the existing own-device rules for business forbid it; follow the contact-sync precedent. |
| S4 | Applying: per conversation keep the max `readUpTo` (`backup_state` key `read-upto:<conversationId>` = ms; last writer wins by max, never decreases). Set `unread_count` to the number of incoming (not own) non-control messages in that conversation with `createdAt` later than `readUpTo` (0 in the normal case). The chat list updates live. |
| S5 | Notifications: when a conversation's unread count drops to 0 through S4, cancel its local notification (`LocalNotifier.cancel(target)` for message and group-message targets). A message that arrives AFTER being read elsewhere (its `createdAt` <= stored `readUpTo` for that conversation) is stored without incrementing unread and without a notification. Server pushes already shown by the OS from the push service (APNs/FCM generic pushes) are cancelled too where the platform plugin allows; state the platforms where it does not in the acceptance doc. |
| S6 | Old app versions on the other device: they do not know `read-state`; follow the precedent of contact-sync (`ownsync-seen:` marker: send only to devices that run an app that understands own-device sync, or accept that an old app leaves it queued up to 30 days, whichever contact-sync does). State it in a compatibility table here. |
| S7 | Backup and history transfer: `read-upto:*` is local state, not backed up. |
| S8 | Bots/archiver: own-device messages never reach bots; `jay_archiver` only if it is an own device of a user (it is not), so no bot change unless tests show otherwise. |

## Tests

- Part 1: unit/flow tests with a fake transport that fails N times then succeeds (message goes `sent` without user action, exactly one envelope delivered); backoff schedule with a fake clock; permanent errors are not retried; 24 h give-up; reconnect trigger; retry in a chat that is not open; duplicate delivery = one bubble.
- Part 2: codec test; inbox test (own device accepted, foreign sender rejected, unknown conversation acked); flow test with `FakeMultiDeviceServer` (phone + web + contact): contact writes, both own devices get unread 1, phone opens the chat, web's unread becomes 0 and its notification is cancelled; out-of-order (older readUpTo ignored); message arriving after readUpTo does not notify.

## Limits
- Retries only while the app runs (no background retry).
- Read state syncs per conversation as "read up to", not per message.
