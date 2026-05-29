import 'package:flutter/material.dart';

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
  const MessageInput({super.key, required this.onSend});

  /// Called with the non-empty trimmed message text when the user submits.
  final ValueChanged<String> onSend;

  @override
  State<MessageInput> createState() => _MessageInputState();
}

class _MessageInputState extends State<MessageInput> {
  final _controller = TextEditingController();

  /// Track whether the text field has content so we can conditionally
  /// enable the send button — prevents sending empty messages.
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    final hasText = _controller.text.trim().isNotEmpty;
    if (hasText != _hasText) {
      setState(() => _hasText = hasText);
    }
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    widget.onSend(text);
    _controller.clear();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            // Attachment button — placeholder for Phase 5 file sharing.
            IconButton(
              icon: const Icon(Icons.attach_file_rounded),
              tooltip: 'Attach file',
              onPressed: () {
                // TODO: Implement file picker in Phase 5.
              },
            ),

            Expanded(
              child: TextField(
                controller: _controller,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  hintText: 'Message',
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
                color: _hasText ? colorScheme.primary : colorScheme.onSurfaceVariant,
              ),
              tooltip: 'Send',
              onPressed: _hasText ? _submit : null,
            ),
          ],
        ),
      ),
    );
  }
}
