import 'package:calltype_core/messaging/reaction.dart'
    show isValidReactionEmoji;

/// Acknowledgement reactions (spec
/// docs/superpowers/specs/2026-11-11-bot-ack-reactions.md): the bot puts
/// [received] on a message it accepted before its turn starts, and replaces
/// it with [answered], [noReply] or [failed] when the turn ends. Pass it to
/// `CallTypeBot.onMessage`; null there = no acknowledgement reactions.
class AckReactions {
  const AckReactions({
    this.received = '👀',
    this.answered = '✅',
    this.noReply = '👍',
    this.failed = '❌',
    this.manual = false,
  });

  /// Put on the message as soon as it is accepted.
  final String received;

  /// The turn sent a reply (text or file) into the conversation.
  final String answered;

  /// The turn ended without sending anything (silent turn).
  final String noReply;

  /// The handler threw, or marked the turn failed.
  final String failed;

  /// False: every message the runtime hands to the handler is accepted
  /// (the allowlist already decided). True: the handler calls
  /// `BotMessage.accept()` itself after its own access rules (bot talk
  /// limits, owner-in-group rules); a message it never accepts gets no
  /// reaction at all.
  final bool manual;
}

/// Told to a model so it can pick the final emoji itself, see
/// [parseReplyDirective].
const ackDirectiveHint =
    'You may start your answer with a line [react:EMOJI] (one emoji, for '
    'example 👍 👀 ✅ ❤️ 😂 🙏 🔥 🎉 🤔 😢 👎) to react to the message. An '
    'answer of only that line sends no text, which fits messages that need '
    'no reply (thanks, ok).';

/// A model's answer, split into an optional reaction directive and the text
/// to post (see [parseReplyDirective]).
typedef ReplyDirective = ({
  /// The emoji to put on the answered message; '' removes the bot's
  /// reaction; null = no (valid) directive.
  String? emoji,

  /// What is left to post. Blank = post no text.
  String text,

  /// The first line was a directive with an invalid emoji. It is stripped
  /// anyway (a broken directive must never reach the user) and [emoji] is
  /// null; the caller logs it.
  bool invalid,
});

/// `[react:EMOJI]` alone on a line; `react` in any case, whitespace allowed
/// around the line, the brackets' content and the colon.
final _directiveLine = RegExp(
  r'^[ \t]*\[[ \t]*react[ \t]*:[ \t]*([^\]\r\n]*?)[ \t]*\][ \t]*$',
  caseSensitive: false,
);

/// Leading blank lines (whitespace-only, any line ending).
final _leadingBlankLines = RegExp(r'^(?:[ \t]*\r?\n)+');

/// A leading directive line, complete or still being streamed (no `]` or
/// no line end yet), for hiding it from a progress message.
final _partialDirective = RegExp(
  r'^\s*\[[ \t]*r(?:e(?:a(?:c(?:t[^\]\r\n]*)?)?)?)?(?:\][ \t]*(?:\r?\n|$)|$)',
  caseSensitive: false,
);

/// Splits [reply] into a reaction directive and the text to post.
///
/// Only the FIRST non-blank line is looked at, and only when it is nothing
/// but the directive: a `[react:...]` further down, or with text after it on
/// the same line, is ordinary text. WHY so strict: the agent may quote the
/// syntax while explaining it, and that must not react.
ReplyDirective parseReplyDirective(String reply) {
  final body = reply.replaceFirst(_leadingBlankLines, '');
  final newline = body.indexOf('\n');
  final first = newline < 0 ? body : body.substring(0, newline);
  final match = _directiveLine.firstMatch(first.replaceAll('\r', ''));
  if (match == null) return (emoji: null, text: reply, invalid: false);
  final rest = newline < 0
      ? ''
      : body.substring(newline + 1).replaceFirst(_leadingBlankLines, '');
  final emoji = match.group(1)!;
  if (emoji.isNotEmpty && !isValidReactionEmoji(emoji)) {
    return (emoji: null, text: rest, invalid: true);
  }
  return (emoji: emoji, text: rest, invalid: false);
}

/// [partial] (a streamed, possibly incomplete answer) without a leading
/// directive line, so a progress message never shows `[react:...]`.
String hideReplyDirective(String partial) =>
    partial.replaceFirst(_partialDirective, '');
