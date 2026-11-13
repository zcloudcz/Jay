import 'package:calltype_core/messaging/group_topic.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/l10n.dart';
import 'group_topic_service.dart';

/// The localized line for a topic save (spec row 14): what was done, or why
/// nothing was sent.
String groupTopicResultText(AppLocalizations l10n, GroupTopicResult result) =>
    switch (result.error) {
      null =>
        result.sent == GroupTopicSent.queued
            ? l10n.groupTopicQueued
            : l10n.groupTopicSaved,
      GroupTopicError.notAdmin => l10n.groupTopicErrorNotAdmin,
      GroupTopicError.unsupported => l10n.groupTopicErrorUnsupported,
      GroupTopicError.business => l10n.groupTopicErrorBusiness,
      GroupTopicError.tooLong => l10n.groupTopicErrorTooLong(
        maxGroupTopicLength,
      ),
      GroupTopicError.failed => l10n.groupTopicErrorFailed,
    };

/// The multiline topic input shared by the create screen and the Edit topic
/// dialog: same limit and counter as the codec enforces.
class GroupTopicField extends StatelessWidget {
  const GroupTopicField({
    super.key,
    required this.controller,
    this.label,
    this.enabled = true,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String? label;
  final bool enabled;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => TextField(
    key: const ValueKey('group-topic-field'),
    controller: controller,
    enabled: enabled,
    autofocus: autofocus,
    minLines: 2,
    maxLines: 6,
    maxLength: maxGroupTopicLength,
    keyboardType: TextInputType.multiline,
    textCapitalization: TextCapitalization.sentences,
    decoration: InputDecoration(
      labelText: label,
      hintText: context.l10n.groupTopicFieldHint,
      border: const OutlineInputBorder(),
    ),
  );
}

/// The Edit topic dialog. Returns the new text, or null when cancelled.
Future<String?> showEditTopicDialog(BuildContext context, String current) =>
    showDialog<String>(
      context: context,
      builder: (_) => _EditTopicDialog(initial: current),
    );

class _EditTopicDialog extends StatefulWidget {
  const _EditTopicDialog({required this.initial});
  final String initial;

  @override
  State<_EditTopicDialog> createState() => _EditTopicDialogState();
}

class _EditTopicDialogState extends State<_EditTopicDialog> {
  late final _text = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.groupTopicEdit),
      content: SizedBox(
        width: 480,
        child: GroupTopicField(controller: _text, autofocus: true),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          key: const ValueKey('group-topic-save'),
          onPressed: () => Navigator.of(context).pop(_text.text),
          child: Text(l10n.commonSave),
        ),
      ],
    );
  }
}

/// Chat header title of a group: the name and, when set, one line of the
/// topic under it (spec row 12). Tapping it opens Group info. In its own
/// widget so the chat screen only swaps one line. The topic comes from the
/// chat controller, which watches the stored value.
class GroupHeaderTitle extends StatelessWidget {
  const GroupHeaderTitle({
    super.key,
    required this.conversationId,
    required this.name,
    required this.topic,
  });

  final String conversationId;
  final String name;
  final String topic;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // One line only: a topic can be 4000 characters with line breaks.
    final firstLine = topic.trim().split('\n').first;
    return InkWell(
      key: const ValueKey('chat-group-header'),
      onTap: () => context.push('/chats/$conversationId/info'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
          if (firstLine.isNotEmpty)
            Text(
              firstLine,
              key: const ValueKey('chat-group-topic'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}
