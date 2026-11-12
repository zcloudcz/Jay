# Bots acknowledge messages with a reaction (contract)

Status: built on `feat/bot-ack-reactions` (`calltype_bot`, `hermes_bridge`, `llm_bridge`, `a2a_bridge`; plus
the notification fix N1-N4: hub silent sends, `calltype_core`, app notifications; no wire payload change, no
migration). Not released. Acceptance: `docs/acceptance/bot-ack-reactions.md`.

Owner (2026-11-11): "potřeboval bych v aplikaci vidět, že Bot přijal zprávu. Discord reaguje emotikonem na
zprávu. Chci to podobně, aby Bot vybral správného emotikona (oko, palec...) a označil zprávu při přečtení.
Nemusí hned reagovat odpovědí, ale vždy by měl přijmout zprávu. Toto je i feedback pro uživatele, že
jay-bridge funguje." And: "I na zprávu jiného bota musí reagovat. Uživatel tak vidí, že interakce funguje."

A bot puts 👀 on every message it accepts, before its turn starts, and replaces it with a final emoji when the
turn ends. No 👀 = the bridge is down or dropped the message. It reuses the chat reactions of
`2026-11-07-message-reactions.md` (`type: reaction`, one reaction per sender per message, newest wins, `""`
removes); nothing new goes over the wire.

## Decisions

| # | Topic | Decision |
|---|---|---|
| R1 | Receipt | When a message is accepted (allowed sender or admitted peer bot, addressed in groups, not a control message, not the bot's own) the bot reacts 👀 BEFORE the turn starts. Implemented once in `calltype_bot` (`onMessage(..., ackReactions: AckReactions())`). A failed reaction send is logged and never blocks or fails the turn. Dropped messages (strangers, unaddressed group chatter, bot talk refused) get nothing. |
| R1a | Who decides "accepted" | `AckReactions(manual: false)` (default): the runtime accepts every message it hands to the handler (`a2a_bridge`: the allowlist already decided). `manual: true`: the handler calls `BotMessage.accept()` after its own access rules (`hermes_bridge`, `llm_bridge`: bot talk limits, owner-in-group rules and the bot-limit notice live in the handler). A message never accepted gets no receipt and no default final emoji. |
| R2 | Final emoji | At the end of an accepted turn the receipt is replaced: ✅ when the turn sent anything through `BotMessage.reply`/`replyFile`, 👍 when it sent nothing, ❌ when the handler threw (the runtime's apology is still posted) or marked the turn failed (`BotMessage.markFailed()`, used when a bridge posts its own error text). The handler can choose the emoji (`BotMessage.finalReaction`; `""` removes the bot's reaction); a failure still wins with ❌. |
| R2a | Model directive | `hermes_bridge` and `llm_bridge`: the FIRST non-blank line of the model's answer may be `[react:EMOJI]` (any case, whitespace allowed, e.g. `[react: 👍]`). It is stripped from the visible text and becomes the final emoji. An answer of only that line sends no text, only the reaction ("díky" -> 👍). `[react:]` removes the bot's reaction. An invalid value is stripped and logged, never shown. The parser moved from `hermes_bridge` to `calltype_bot` (`parseReplyDirective`, re-exported by `hermes_bridge`) so both bridges share it. |
| R2b | Emoji set (deviation) | Any ONE emoji that passes `isValidReactionEmoji`, not an allowlist. WHY: `hermes_bridge` already shipped `[react:EMOJI]` with any valid emoji (tests cover flags and keycaps); the validator already guarantees a single grapheme, and the app renders every emoji. The hint suggests the common set (👍 👀 ✅ ❤️ 😂 🙏 🔥 🎉 🤔 😢 👎 ❌). |
| R2c | Hints | `llm_bridge` appends one line about the directive to every system prompt (default AND `LLM_SYSTEM_PROMPT`, like the image hint: a custom prompt would otherwise never learn it). `hermes_bridge` keeps its once-per-conversation `reactDirectiveHint`, now mentioning the no-text acknowledgement. While streaming, `llm_bridge` hides a leading directive line from the progress message. |
| R3 | Long turns | Unchanged "Working on it..." progress behaviour; 👀 stays until the final emoji. No ⏳. |
| R4 | Config | Env `ACK_REACTIONS=on\|off` (default on) in `llm_bridge`, `hermes_bridge`, `a2a_bridge`. Off = no 👀 and no default final emoji; the model's directive keeps working (in `hermes_bridge` it predates this feature). `a2a_bridge`: R1 + R2 defaults only, no directive. `jay_archiver`: none (it never reacts). |
| R5 | Groups | Same behaviour; the reaction is visible to every member. |
| R6 | Bot-to-bot | A peer bot's message that this bot HANDLES (bot talk allows it, under the limit, not paused) gets 👀 and the final emoji like a human's. Refused bot messages (bot talk off, limit reached incl. the one limit notice, pause) get nothing. No ping-pong: reactions never start a turn. `hermes_bridge` forwards only owners' reactions (REACTION_MODE), `llm_bridge` and `a2a_bridge` set no reaction handler (runtime acks and ignores). Tested in each bridge. |
| R7 | Owner reactions | `REACTION_MODE` unchanged. The bot's own reaction echoes are never input (the runtime drops copies from its own devices before any handler). |
| R8 | Ordering | The final emoji is sent after the receipt send finished (success or failure); reactions are last-writer-wins by `createdAt`, equal timestamps by arrival, so the final emoji always replaces 👀. |
| R9 | Button presses | A press handled by the normal message path is a message like any other (receipt + final). Approval presses in `hermes_bridge` are not accepted (no reaction). |

## Notifications (N1-N4)

Owner (2026-11-12): "doplnit a vydat" for the fix of the notification limit below. Every reaction is an
encrypted message, so without it an acknowledged turn could add two app notifications ("X reacted 👀 to ...")
and two generic "New message" pushes.

| # | Topic | Decision |
|---|---|---|
| N1 | Server: silent sends | New hub methods `SendReliableMessageSilent`, `SendReliableGroupMessageSilent`, `SendReliableDirectFanoutSilent`, `SendReliableGroupFanoutSilent` (partial `Hubs/MessengerHub.Silent.cs`), same arguments as the plain methods. Validation, bot inbound policy, storage and live delivery are the plain method's own code (shared private core with a `silent` flag); only the push to an offline device is skipped, so mutes are not even queried. The flag is not stored: it only decides the push at send time, and no other path pushes a queued message later (replay on connect never pushes). No migration. Call ring and `incoming_call` pushes are untouched. |
| N1a | Deviation: names, not an optional argument | The task asked for an optional `silent` argument or overload. ASP.NET Core SignalR binds hub arguments by COUNT and rejects overloads, so an extra optional parameter would break every old client calling with today's count (same reason `BusinessCallSignal` is a separate method). Twin methods keep the old ones unchanged. |
| N2 | Clients | `calltype_core` `SignalRClient.sendMessage` (reliable only), `sendGroupMessage`, `sendDirectFanout`, `sendGroupFanout` take `silent` (default false) and call the `...Silent` twin. `calltype_bot` sends EVERY reaction silently: the 👀 receipt, the final emoji, the `[react:EMOJI]` directive, `BotMessage.react`/`removeReaction` and `CallTypeBot.sendReaction` (also the business-group per-member path). Replies and other messages stay plain. |
| N2a | Human reactions | Unchanged, not silent: the app already notifies for a human's reaction on your own message, and a push is the only way an offline phone learns it. The app does not use `silent`. |
| N3 | App notifications | `NotificationService.onReaction` never notifies for a bot's reaction (contact `isBot`; for a non-contact, e.g. a bot met in a group, the server profile `GET /devices/{id}/profile`, asked once per identity and run, a failed lookup counts as no bot and is asked again) and never for a reaction that replaces an earlier row of the same sender on the same message (`AppliedReaction.replaced`, read before applying). WHY also a re-add after a removal: toggling a reaction should not ring twice. Removals never notified. Human first reactions keep today's behaviour (mute, open chat, previews). |
| N4 | Compatibility | New bot + old server: the `...Silent` call fails while binding with `Failed to invoke '<name>' due to an error on the server.` (nothing queued, pinned by `MutePushTests`); `SignalRClient` then sends the same envelopes with the same message id through the plain method and remembers it until the next connect (that only costs the push the old server always sent). Errors thrown inside a hub method read differently and are never a fallback. New server + old bot: the old methods are unchanged, behaviour as before. Old app + bot reactions: the app's own notification rule decides (it still notifies for a bot reaction); the push is gone. |

Tests: `MutePushTests` (silent 1:1 and fan-out stored, delivered on connect, no push; silent group per-member
and fan-out no push while the plain fan-out still pushes; validation unchanged; unknown method text),
`signalr_client_test` (twin names, fallback, no fallback on a hub error), `calltype_bot`
`reaction_send_test` (reactions silent, replies not, business path, old server fallback), app
`notification_service_test`, `notification_directory_test`, `message_reactions_inbox_test` (replaced flag).

## Runtime API (`calltype_bot`)

```dart
class AckReactions {
  const AckReactions({String received = '👀', String answered = '✅',
      String noReply = '👍', String failed = '❌', bool manual = false});
}
Future<void> onMessage(BotMessageHandler handler, {..., AckReactions? ackReactions}); // null = off

// BotMessage
Future<void> accept();          // receipt once; no-op when off or already sent; never throws
bool get accepted;
String? finalReaction;          // handler's choice; '' removes; invalid -> logged, default used
void markFailed();              // final emoji = failed
bool get replied;               // reply()/replyFile() succeeded during this turn

ReplyDirective parseReplyDirective(String reply); // ({String? emoji, String text, bool invalid})
const ackDirectiveHint = '...';
```

## Compatibility

No payload change; the only wire addition is the `...Silent` hub methods (N1, N4). Old apps that do not know
reactions keep the reaction envelopes queued like any reaction (same accepted cost as in the reactions
contract). Every reaction is one more envelope per recipient device: two per accepted message, neither of them
pushed.

## Limits

- The final emoji is sent after the turn; if the process dies mid-turn 👀 stays.
- "Answered" means a reply went through `BotMessage.reply`/`replyFile`; a bridge sending into the same chat
  by other means (`bot.send`) does not count.
- At most once, like turns: a re-delivered message (seen-row) gets no second receipt.
- Notifications: fixed by N1-N4. Left over: an OLD app still shows "X reacted 👀 to: ..." for a bot's
  reaction while it runs in the background (no push needed for that); an offline device learns about a
  bot's reaction only when it next connects, which is the point. The server trusts the sender's `silent`:
  a sender can only make its own messages quieter, never louder.
- App display: checked, no change needed. The inbox applies a reaction from any authenticated sender in
  the conversation (bots included) to a message of that conversation, the user's own messages included,
  last writer wins with equal timestamps applied; the chips render under incoming and outgoing bubbles.
  Covered by `message_reactions_inbox_test` ("stores the reaction under the authenticated sender").
