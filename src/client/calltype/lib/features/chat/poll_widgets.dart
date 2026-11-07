import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import 'polls.dart';

/// The poll inside a chat bubble (spec 2026-11-08-chat-extras): question,
/// options with live bars and counts, the local user's picks. A tap on an
/// option changes the vote: single choice picks it (or withdraws it when it
/// was the pick), multiple choice toggles it.
class PollCard extends StatelessWidget {
  const PollCard({
    super.key,
    required this.results,
    required this.textColor,
    this.onVote,
    this.onShowVoters,
  });

  final PollResults results;
  final Color textColor;

  /// The new full set of picks; null = voting not possible (pending send,
  /// business conversation).
  final void Function(List<int> options)? onVote;
  final VoidCallback? onShowVoters;

  List<int> _toggle(int option) {
    final mine = results.mine;
    if (!results.poll.multiple) {
      return mine.length == 1 && mine.single == option ? const [] : [option];
    }
    final next = {...mine};
    if (!next.remove(option)) next.add(option);
    return next.toList()..sort();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final poll = results.poll;
    final muted = textColor.withAlpha(170);
    return SizedBox(
      width: 280,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            poll.question,
            style: theme.textTheme.titleSmall?.copyWith(color: textColor),
          ),
          const SizedBox(height: 2),
          Text(
            poll.multiple ? l10n.pollSelectMany : l10n.pollSelectOne,
            style: theme.textTheme.labelSmall?.copyWith(color: muted),
          ),
          const SizedBox(height: 6),
          for (final (index, option) in poll.options.indexed)
            _PollOptionRow(
              key: ValueKey('poll-option-$index'),
              label: option,
              count: results.countOf(index),
              fraction: results.voterCount == 0
                  ? 0
                  : results.countOf(index) / results.voterCount,
              selected: results.mine.contains(index),
              multiple: poll.multiple,
              textColor: textColor,
              onTap: onVote == null ? null : () => onVote!(_toggle(index)),
            ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.pollVotesCount(results.voterCount),
                  style: theme.textTheme.labelSmall?.copyWith(color: muted),
                ),
              ),
              if (onShowVoters != null && results.voterCount > 0)
                TextButton(
                  key: const ValueKey('poll-view-votes'),
                  onPressed: onShowVoters,
                  child: Text(l10n.pollViewVotes),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PollOptionRow extends StatelessWidget {
  const _PollOptionRow({
    super.key,
    required this.label,
    required this.count,
    required this.fraction,
    required this.selected,
    required this.multiple,
    required this.textColor,
    required this.onTap,
  });

  final String label;
  final int count;
  final double fraction;
  final bool selected;
  final bool multiple;
  final Color textColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = multiple
        ? (selected ? Icons.check_box_rounded : Icons.check_box_outline_blank)
        : (selected
              ? Icons.radio_button_checked
              : Icons.radio_button_unchecked);
    return Semantics(
      selected: selected,
      button: onTap != null,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Icon(icon, size: 20, color: textColor),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            label,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: textColor,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '$count',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: textColor,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: fraction,
                        minHeight: 4,
                        color: theme.colorScheme.primary,
                        backgroundColor: textColor.withAlpha(40),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Who voted for which option ([nameOf] turns an identity into a label).
Future<void> showPollVotersSheet(
  BuildContext context, {
  required PollResults results,
  required String Function(String identityId) nameOf,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (sheetContext) {
    final l10n = sheetContext.l10n;
    final theme = Theme.of(sheetContext);
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l10n.pollVotersTitle, style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(results.poll.question, style: theme.textTheme.bodyMedium),
              for (final (index, option) in results.poll.options.indexed) ...[
                const SizedBox(height: 12),
                Text(
                  '$option (${results.countOf(index)})',
                  style: theme.textTheme.titleSmall,
                ),
                if (results.votersByOption[index].isEmpty)
                  Text(l10n.pollNoVotes, style: theme.textTheme.bodySmall)
                else
                  for (final voter in results.votersByOption[index])
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(nameOf(voter)),
                    ),
              ],
            ],
          ),
        ),
      ),
    );
  },
);

/// The poll composer; returns the poll to send, or null on cancel.
Future<PollPayload?> showPollComposer(BuildContext context) =>
    showDialog<PollPayload>(
      context: context,
      builder: (_) => const PollComposerDialog(),
    );

class PollComposerDialog extends StatefulWidget {
  const PollComposerDialog({super.key});

  @override
  State<PollComposerDialog> createState() => _PollComposerDialogState();
}

class _PollComposerDialogState extends State<PollComposerDialog> {
  final _question = TextEditingController();
  final _options = [TextEditingController(), TextEditingController()];
  bool _multiple = false;
  bool _showError = false;

  @override
  void dispose() {
    _question.dispose();
    for (final option in _options) {
      option.dispose();
    }
    super.dispose();
  }

  void _send() {
    final options = [
      for (final o in _options)
        if (o.text.trim().isNotEmpty) o.text,
    ];
    final problem = PollPayload.problemOf(
      _question.text,
      options,
      multiple: _multiple,
    );
    if (problem != null) {
      setState(() => _showError = true);
      return;
    }
    Navigator.of(context).pop(
      PollPayload.create(
        question: _question.text,
        options: options,
        multiple: _multiple,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.pollCreateTitle),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const ValueKey('poll-question'),
                controller: _question,
                autofocus: true,
                maxLength: maxPollQuestionLength,
                minLines: 1,
                maxLines: 3,
                decoration: InputDecoration(labelText: l10n.pollQuestionLabel),
              ),
              for (final (index, option) in _options.indexed)
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: ValueKey('poll-option-field-$index'),
                        controller: option,
                        maxLength: maxPollOptionLength,
                        decoration: InputDecoration(
                          labelText: l10n.pollOptionLabel(index + 1),
                        ),
                      ),
                    ),
                    if (_options.length > minPollOptions)
                      IconButton(
                        icon: const Icon(Icons.remove_circle_outline),
                        tooltip: l10n.pollRemoveOption,
                        onPressed: () => setState(() {
                          _options.removeAt(index).dispose();
                        }),
                      ),
                  ],
                ),
              if (_options.length < maxPollOptions)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    key: const ValueKey('poll-add-option'),
                    onPressed: () =>
                        setState(() => _options.add(TextEditingController())),
                    icon: const Icon(Icons.add),
                    label: Text(l10n.pollAddOption),
                  ),
                ),
              SwitchListTile(
                key: const ValueKey('poll-multiple'),
                contentPadding: EdgeInsets.zero,
                value: _multiple,
                onChanged: (value) => setState(() => _multiple = value),
                title: Text(l10n.pollMultipleAnswers),
              ),
              if (_showError)
                Text(
                  l10n.pollInvalid,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          key: const ValueKey('poll-send'),
          onPressed: _send,
          child: Text(l10n.pollSend),
        ),
      ],
    );
  }
}
