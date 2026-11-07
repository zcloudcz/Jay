import 'package:calltype_bot/calltype_bot.dart' show isValidReactionEmoji;

/// The agent's reply, split into an optional reaction directive and the text
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
