import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../shared/widgets/bot_badge.dart';
import 'mentions.dart';

/// Composable message input bar with text field and send button.
///
/// Sits at the bottom of the chat screen. Calls [onSend] with the
/// trimmed text when the user taps send or presses Enter, then clears
/// the field. The attachment button is a placeholder for Phase 5 (file
/// sharing).
///
/// Owns its own [TextEditingController] and disposes it properly to
/// avoid memory leaks — this is important because the input bar lives
/// as long as the chat screen and the controller holds native resources.
class MessageInput extends StatefulWidget {
  const MessageInput({
    super.key,
    required this.onSend,
    this.onAttachment,
    this.mentionCandidates = const [],
    this.replyAuthor,
    this.replyText,
    this.onCancelReply,
  });
  final VoidCallback? onAttachment;

  /// Reply bar above the field; shown while [replyText] is non-null.
  final String? replyAuthor;
  final String? replyText;
  final VoidCallback? onCancelReply;

  /// Group members offered while the user types `@...`; empty in direct chats.
  final List<MentionCandidate> mentionCandidates;

  /// Called with the non-empty trimmed message text when the user submits.
  final Future<void> Function(String) onSend;

  @override
  State<MessageInput> createState() => _MessageInputState();
}

class _MessageInputState extends State<MessageInput> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  /// Suggestions currently shown above the field. Kept as state (instead of
  /// recomputed in build) so setState runs only when the visible list changes.
  MentionQuery? _mention;
  List<MentionCandidate> _suggestions = const [];

  /// Track whether the text field has content so we can conditionally
  /// enable the send button — prevents sending empty messages.
  bool _hasText = false;
  bool _sending = false;

  @override
  void didUpdateWidget(MessageInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Choosing "Reply" means "I want to type now": put the cursor in the
    // field so the user does not have to click or tap it first.
    if (widget.replyText != null && oldWidget.replyText == null) {
      _focus.requestFocus();
    }
  }

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    final hasText = _controller.text.trim().isNotEmpty;
    final cursor = _controller.selection.baseOffset;
    final mention = activeMentionQuery(_controller.text, cursor);
    final suggestions = mention == null
        ? const <MentionCandidate>[]
        : filterMentions(widget.mentionCandidates, mention.query);
    final changed =
        suggestions.length != _suggestions.length ||
        !suggestions.indexed.every((e) => identical(e.$2, _suggestions[e.$1]));
    if (hasText != _hasText || changed) {
      setState(() {
        _hasText = hasText;
        _mention = mention;
        _suggestions = suggestions;
      });
    }
  }

  void _pick(MentionCandidate candidate) {
    final mention = _mention;
    if (mention == null) return;
    final cursor = _controller.selection.baseOffset;
    final result = applyMention(
      _controller.text,
      mention,
      cursor,
      candidate.token,
    );
    _controller.value = TextEditingValue(
      text: result.text,
      selection: TextSelection.collapsed(offset: result.cursor),
    );
    _focus.requestFocus();
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.onSend(text);
      if (mounted && _controller.text.trim() == text) _controller.clear();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.chatInputNotSaved)),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_suggestions.isNotEmpty)
            Material(
              color: colorScheme.surfaceContainer,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _suggestions.length,
                  itemBuilder: (context, i) {
                    final c = _suggestions[i];
                    return ListTile(
                      dense: true,
                      title: NameWithBotBadge(name: c.label, isBot: c.isBot),
                      subtitle: c.detail == null ? null : Text(c.detail!),
                      onTap: () => _pick(c),
                    );
                  },
                ),
              ),
            ),
          if (widget.replyText != null)
            Container(
              margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              padding: const EdgeInsetsDirectional.only(start: 10),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                border: BorderDirectional(
                  start: BorderSide(color: colorScheme.primary, width: 3),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (widget.replyAuthor != null)
                          Text(
                            widget.replyAuthor!,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: colorScheme.primary,
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                        Text(
                          widget.replyText!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    tooltip: context.l10n.chatReplyCancel,
                    onPressed: widget.onCancelReply,
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: [
                // Attachment button — placeholder for Phase 5 file sharing.
                IconButton(
                  icon: const Icon(Icons.attach_file_rounded),
                  tooltip: context.l10n.chatInputAttach,
                  onPressed: widget.onAttachment,
                ),

                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focus,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      hintText: context.l10n.chatInputHint,
                      filled: true,
                      fillColor: colorScheme.surfaceContainerHighest,
                      // Fully rounded ends give the input field the pill shape
                      // that's become standard in messaging app UIs.
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),

                const SizedBox(width: 4),

                // Send button — visually distinct when text is present to
                // signal that the message is ready to send.
                IconButton(
                  icon: Icon(
                    Icons.send_rounded,
                    color: _hasText
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                  ),
                  tooltip: context.l10n.chatInputSend,
                  onPressed: _hasText && !_sending ? _submit : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
