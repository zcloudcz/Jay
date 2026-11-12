# Bots acknowledge messages with a reaction (contract)

Status: built on `feat/bot-ack-reactions` (`calltype_bot`, `hermes_bridge`, `llm_bridge`, `a2a_bridge`; no
server, protocol or app change). Not released.

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

No wire change. Old apps that do not know reactions keep the reaction envelopes queued like any reaction
(same accepted cost as in the reactions contract). Every reaction is one more envelope per recipient device:
two per accepted message.

## Limits

- The final emoji is sent after the turn; if the process dies mid-turn 👀 stays.
- "Answered" means a reply went through `BotMessage.reply`/`replyFile`; a bridge sending into the same chat
  by other means (`bot.send`) does not count.
- At most once, like turns: a re-delivered message (seen-row) gets no second receipt.
