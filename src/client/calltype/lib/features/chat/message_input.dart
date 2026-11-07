import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../shared/widgets/bot_badge.dart';
import 'bot_commands.dart';
import 'mentions.dart';

/// Composable message input bar with text field and send button.
///
/// Sits at the bottom of the chat screen. Calls [onSend] with the
/// trimmed text when the user taps send (or presses Enter where
/// [enterSends]), then clears the field. The field grows to
/// [maxComposerLines] lines and scrolls inside after that.
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
    this.onSendWithMentions,
    this.commandSuggestions,
    this.initialText,
    this.loadDraft,
    this.saveDraft,
    this.enterSends,
  });

  /// Lines the field grows to before it scrolls inside.
  static const maxComposerLines = 6;

  /// Whether a hardware Enter sends (Shift+Enter = new line), the default
  /// on web and desktop. On iOS / Android Enter inserts a new line and the
  /// send button sends, as in other messengers. Injected by tests; null =
  /// decided by the platform.
  final bool? enterSends;

  /// Reads the stored unsent text of this conversation; used only when
  /// [initialText] is empty (an explicit pre-fill wins).
  final Future<String?> Function()? loadDraft;

  /// Persists the current text (debounced, flushed when the app goes to the
  /// background, on dispose and right after a send). Blank = remove.
  final Future<void> Function(String text)? saveDraft;
  final VoidCallback? onAttachment;

  /// Used instead of [onSend] when set: also gets the identity ids of the
  /// picked @mentions still present in the text (contract section 8).
  final Future<void> Function(String text, List<String> mentions)?
  onSendWithMentions;

  /// Loads the "/" menu; null when the chat has no bot (no menu at all).
  /// Called each time a `/` starts the text, the caller caches.
  final Future<List<CommandSuggestion>> Function()? commandSuggestions;

  /// Pre-filled, NOT sent (bot deep link `/start <payload>`): the user
  /// reviews it and presses send.
  final String? initialText;

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

class _MessageInputState extends State<MessageInput>
    with WidgetsBindingObserver {
  final _controller = TextEditingController();
  late final _focus = FocusNode(onKeyEvent: _onKey);

  Timer? _draftTimer;

  /// The text last handed to [MessageInput.saveDraft] (or loaded): an
  /// untouched composer never writes.
  String _savedDraft = '';
  static const _draftDelay = Duration(milliseconds: 400);

  bool get _enterSends =>
      widget.enterSends ??
      (kIsWeb ||
          switch (defaultTargetPlatform) {
            TargetPlatform.android ||
            TargetPlatform.iOS ||
            TargetPlatform.fuchsia => false,
            TargetPlatform.linux ||
            TargetPlatform.macOS ||
            TargetPlatform.windows => true,
          });

  /// Suggestions currently shown above the field. Kept as state (instead of
  /// recomputed in build) so setState runs only when the visible list changes.
  MentionQuery? _mention;
  List<MentionCandidate> _suggestions = const [];

  /// Mentions picked from the list since the field was last cleared; on
  /// send only those whose `@token` survived editing are reported.
  final _picked = <PickedMention>[];

  /// The "/" menu: [_commands] is the loaded list for the current `/` word
  /// (null = not loaded), [_commandQuery] what is typed after the slash.
  List<CommandSuggestion>? _commands;
  String? _commandQuery;
  List<CommandSuggestion> _commandMatches = const [];
  int _commandLoad = 0;

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
    final initial = widget.initialText;
    if (initial != null && initial.isNotEmpty) {
      _controller.value = TextEditingValue(
        text: initial,
        selection: TextSelection.collapsed(offset: initial.length),
      );
      _hasText = initial.trim().isNotEmpty;
      // What the user now sees replaces an older stored draft.
      _flushDraft();
    } else {
      _restoreDraft();
    }
    _controller.addListener(_onTextChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  Future<void> _restoreDraft() async {
    final load = widget.loadDraft;
    if (load == null) return;
    String? draft;
    try {
      draft = await load();
    } catch (_) {
      return;
    }
    // Typing that started before the load finished wins over the old draft.
    if (!mounted || draft == null || _controller.text.isNotEmpty) return;
    _savedDraft = draft;
    _controller.value = TextEditingValue(
      text: draft,
      selection: TextSelection.collapsed(offset: draft.length),
    );
  }

  void _scheduleDraft() {
    if (widget.saveDraft == null) return;
    _draftTimer?.cancel();
    _draftTimer = Timer(_draftDelay, _flushDraft);
  }

  void _flushDraft() {
    _draftTimer?.cancel();
    _draftTimer = null;
    final save = widget.saveDraft;
    final text = _controller.text;
    if (save == null || text == _savedDraft) return;
    _savedDraft = text;
    unawaited(save(text).catchError((Object _) {}));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The OS may kill a backgrounded app without another callback.
    if (state != AppLifecycleState.resumed) _flushDraft();
  }

  /// Web / desktop: Enter sends, Shift+Enter falls through to the text
  /// input, which inserts the new line. Not while an IME is composing:
  /// there Enter commits the composition.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_enterSends || event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isShiftPressed ||
        _controller.value.composing.isValid) {
      return KeyEventResult.ignored;
    }
    unawaited(_submit());
    return KeyEventResult.handled;
  }

  /// Opens / filters / closes the "/" menu for the current text.
  void _updateCommands(String text, int cursor) {
    final load = widget.commandSuggestions;
    final query = load == null ? null : activeCommandQuery(text, cursor);
    if (query == null) {
      if (_commandQuery != null || _commandMatches.isNotEmpty) {
        setState(() {
          _commandQuery = null;
          _commands = null;
          _commandMatches = const [];
        });
      }
      return;
    }
    final wasClosed = _commandQuery == null;
    _commandQuery = query;
    if (wasClosed || _commands == null) {
      // A new "/" word: (re)load. The token guards against a slow answer
      // for an earlier "/" landing after the user moved on.
      final token = ++_commandLoad;
      load!().then((commands) {
        if (!mounted || token != _commandLoad || _commandQuery == null) return;
        setState(() {
          _commands = commands;
          _commandMatches = filterCommands(commands, _commandQuery!);
        });
      }, onError: (Object _) {});
    }
    final commands = _commands;
    if (commands != null) {
      setState(() => _commandMatches = filterCommands(commands, query));
    }
  }

  void _pickCommand(CommandSuggestion command) {
    final cursor = _controller.selection.baseOffset;
    final text = _controller.text;
    final end = cursor < 0 || cursor > text.length ? text.length : cursor;
    final result = text.replaceRange(0, end, command.insert);
    _controller.value = TextEditingValue(
      text: result,
      selection: TextSelection.collapsed(offset: command.insert.length),
    );
    _focus.requestFocus();
  }

  void _onTextChanged() {
    if (_controller.text != _savedDraft) _scheduleDraft();
    final hasText = _controller.text.trim().isNotEmpty;
    final cursor = _controller.selection.baseOffset;
    if (_controller.text.isEmpty) _picked.clear();
    _updateCommands(_controller.text, cursor);
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
    final id = candidate.id;
    if (id != null) _picked.add((token: candidate.token, id: id));
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
      final withMentions = widget.onSendWithMentions;
      if (withMentions != null) {
        await withMentions(text, mentionedIds(text, _picked));
      } else {
        await widget.onSend(text);
      }
      if (mounted && _controller.text.trim() == text) {
        _controller.clear();
        // Sent: the stored draft goes now, not after the debounce.
        _flushDraft();
      }
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
    WidgetsBinding.instance.removeObserver(this);
    _flushDraft();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  // One tap region with the text field: tapping send, attach or a
  // suggestion is not a "tap outside" that would drop the keyboard first.
  @override
  Widget build(BuildContext context) =>
      TextFieldTapRegion(child: _buildBar(context));

  Widget _buildBar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_commandMatches.isNotEmpty)
            Material(
              color: colorScheme.surfaceContainer,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: ListView.builder(
                  shrinkWrap: true,
                  // Scrolling the suggestions must keep the keyboard up.
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.manual,
                  itemCount: _commandMatches.length,
                  itemBuilder: (context, i) {
                    final c = _commandMatches[i];
                    return ListTile(
                      dense: true,
                      // A command is a protocol token, never translated.
                      title: Text('/${c.command}'),
                      subtitle: Text(
                        c.botName == null
                            ? c.description
                            : context.l10n.chatCommandFromBot(
                                c.description,
                                c.botName!,
                              ),
                      ),
                      onTap: () => _pickCommand(c),
                    );
                  },
                ),
              ),
            ),
          if (_suggestions.isNotEmpty)
            Material(
              color: colorScheme.surfaceContainer,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: ListView.builder(
                  shrinkWrap: true,
                  // Scrolling the suggestions must keep the keyboard up.
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.manual,
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
              // Side buttons stay at the bottom line while the field grows.
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  icon: const Icon(Icons.attach_file_rounded),
                  tooltip: context.l10n.chatInputAttach,
                  onPressed: widget.onAttachment,
                ),

                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focus,
                    minLines: 1,
                    maxLines: MessageInput.maxComposerLines,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    textCapitalization: TextCapitalization.sentences,
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
