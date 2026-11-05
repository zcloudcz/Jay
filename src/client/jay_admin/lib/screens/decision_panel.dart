import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/models.dart';
import '../app.dart';
import '../ui/format.dart';

/// Actions the panel offers for this subject, in the order of the rules'
/// "mildest first" list (rules section 5).
List<String> availableActions(CaseDetail d, {String? postId}) {
  if (d.channel.deleted) return const [];
  return [
    if (d.openReports > 0) 'dismiss',
    if (postId != null && d.post != null && !d.post!.deleted) 'remove_post',
    if (!d.channel.isSuspended) 'suspend_channel',
    if (d.channel.isSuspended) 'restore_channel',
    'terminate_channel',
  ];
}

bool actionNeedsGround(String? a) =>
    a == 'remove_post' || a == 'suspend_channel' || a == 'terminate_channel';

bool isDestructive(String? a) => actionNeedsGround(a);

/// Right column of the case: action, ground (rule or law), explanation,
/// suspension length, live preview of the owner's statement and a
/// confirmation step. Validation mirrors POST /admin/decisions (contract 4.6)
/// so the operator fixes mistakes before the server's 400.
class DecisionPanel extends StatefulWidget {
  const DecisionPanel({super.key, required this.detail, required this.postId, required this.onDecided});

  final CaseDetail detail;
  final String? postId;
  final ValueChanged<Decision> onDecided;

  @override
  State<DecisionPanel> createState() => _DecisionPanelState();
}

class _DecisionPanelState extends State<DecisionPanel> {
  final _form = GlobalKey<FormState>();
  final _legal = TextEditingController();
  final _explanation = TextEditingController();
  final _days = TextEditingController(text: '7');
  String? _action;
  String? _ground;
  String? _rule;
  bool _busy = false;
  bool _submitted = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Rebuild on every keystroke: the statement preview is live.
    for (final c in [_legal, _explanation, _days]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    _legal.dispose();
    _explanation.dispose();
    _days.dispose();
    super.dispose();
  }

  int? get _suspendDays => int.tryParse(_days.text.trim());

  StatementDraft _draft() => StatementDraft(
    action: _action ?? 'dismiss',
    channelLabel: '${widget.detail.channel.name} (${widget.detail.channel.handle})',
    ground: actionNeedsGround(_action) ? _ground : null,
    rule: _ground == 'terms' ? _rule : null,
    legalGround: _ground == 'illegal' ? _legal.text : null,
    explanation: _explanation.text,
    suspendDays: _suspendDays,
    // Matches the server: basedOnReports = the decision resolved >= 1 report.
    // Restore leaves reports untouched (contract 4.6).
    basedOnReports: _action != 'restore_channel' && widget.detail.openReports > 0,
  );

  Future<void> _submit() async {
    setState(() {
      _submitted = true;
      _error = null;
    });
    if (_action == null || !_form.currentState!.validate()) return;
    final l = context.l10n;
    final preview = statementPreview(l, context.lang, _draft());
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => ConfirmDecisionDialog(
        actionLabel: actionLabel(l, _action!),
        preview: preview,
        destructive: isDestructive(_action),
        requiredHandle: _action == 'terminate_channel' ? widget.detail.channel.handle : null,
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final decision = await AdminScope.of(context).api.decide(
        DecisionRequest(
          channelId: widget.detail.channel.channelId,
          postId: _action == 'remove_post' || (_action == 'dismiss' && widget.postId != null) ? widget.postId : null,
          action: _action!,
          ground: actionNeedsGround(_action) ? _ground : null,
          rule: actionNeedsGround(_action) && _ground == 'terms' ? _rule : null,
          legalGround: actionNeedsGround(_action) && _ground == 'illegal' ? _legal.text.trim() : null,
          explanation: _explanation.text.trim(),
          suspendDays: _action == 'suspend_channel' ? _suspendDays : null,
        ),
      );
      if (!mounted) return;
      setState(() => _busy = false);
      widget.onDecided(decision);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = errorMessage(l, e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = Theme.of(context);
    final actions = availableActions(widget.detail, postId: widget.postId);
    if (actions.isEmpty) {
      return Card(child: Padding(padding: const EdgeInsets.all(16), child: Text(l.noActionAvailable)));
    }
    final preview = _action == null ? null : statementPreview(l, context.lang, _draft());
    final reporterStatus = _action == 'dismiss' ? l.reportStatusDismissed : l.reportStatusActioned;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _form,
          autovalidateMode: _submitted ? AutovalidateMode.always : AutovalidateMode.disabled,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l.decisionTitle, style: t.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(l.actionLabel, style: t.textTheme.labelMedium),
              RadioGroup<String>(
                groupValue: _action,
                onChanged: (v) => setState(() => _action = v),
                child: Column(
                  children: [
                    for (final a in actions)
                      RadioListTile<String>(
                        key: Key('action-$a'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: a,
                        title: Text(
                          actionLabel(l, a),
                          style: isDestructive(a) ? TextStyle(color: t.colorScheme.error) : null,
                        ),
                      ),
                  ],
                ),
              ),
              if (_submitted && _action == null)
                Text(l.actionRequired, key: const Key('action-required'), style: TextStyle(color: t.colorScheme.error)),
              if (actionNeedsGround(_action)) ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  key: const Key('ground'),
                  initialValue: _ground,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: l.groundLabel),
                  items: [
                    DropdownMenuItem(value: 'terms', child: Text(l.groundTerms)),
                    DropdownMenuItem(value: 'illegal', child: Text(l.groundIllegal)),
                  ],
                  onChanged: (v) => setState(() => _ground = v),
                  validator: (v) => v == null ? l.groundRequired : null,
                ),
                if (_ground == 'terms') ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          key: const Key('rule'),
                          initialValue: _rule,
                          isExpanded: true,
                          decoration: InputDecoration(labelText: l.ruleLabel),
                          items: [
                            for (final r in Rules.ids)
                              DropdownMenuItem(value: r, child: Text('$r ${ruleTitle(l, r)}', overflow: TextOverflow.ellipsis)),
                          ],
                          onChanged: (v) => setState(() => _rule = v),
                          validator: (v) => v == null ? l.ruleRequired : null,
                        ),
                      ),
                      IconButton(
                        tooltip: l.ruleOpen,
                        icon: const Icon(Icons.open_in_new),
                        onPressed: () => AdminScope.of(context).browser.openUrl(Rules.url(_rule ?? 'K1', context.lang)),
                      ),
                    ],
                  ),
                ],
                if (_ground == 'illegal') ...[
                  const SizedBox(height: 8),
                  TextFormField(
                    key: const Key('legal-ground'),
                    controller: _legal,
                    maxLength: 300,
                    decoration: InputDecoration(labelText: l.legalGroundLabel, helperText: l.legalGroundHelper),
                    validator: (v) {
                      final n = (v ?? '').trim().length;
                      return n < 1 || n > 300 ? l.legalGroundRequired : null;
                    },
                  ),
                ],
              ],
              if (_action == 'suspend_channel') ...[
                const SizedBox(height: 8),
                TextFormField(
                  key: const Key('suspend-days'),
                  controller: _days,
                  decoration: InputDecoration(labelText: l.suspendDaysLabel),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  validator: (v) {
                    final d = int.tryParse((v ?? '').trim());
                    return d == null || d < 1 || d > 365 ? l.suspendDaysInvalid : null;
                  },
                ),
              ],
              if (_action != null) ...[
                const SizedBox(height: 8),
                TextFormField(
                  key: const Key('explanation'),
                  controller: _explanation,
                  minLines: 3,
                  maxLines: 8,
                  maxLength: 2000,
                  decoration: InputDecoration(
                    labelText: l.explanationLabel,
                    helperText: l.explanationHelper,
                    border: const OutlineInputBorder(),
                  ),
                  validator: (v) {
                    final n = (v ?? '').trim().length;
                    return n < 1 || n > 2000 ? l.explanationRequired : null;
                  },
                ),
                const SizedBox(height: 12),
                Text(l.previewTitle, style: t.textTheme.labelLarge),
                const SizedBox(height: 4),
                Container(
                  key: const Key('statement-preview'),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: t.colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: t.colorScheme.outlineVariant),
                  ),
                  child: SelectableText(preview ?? l.previewDismiss),
                ),
                const SizedBox(height: 6),
                Text(
                  widget.detail.openReports > 0 && _action != 'restore_channel'
                      ? l.previewReporters(reporterStatus)
                      : l.previewNoReporters,
                  style: t.textTheme.bodySmall,
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, key: const Key('decision-error'), style: TextStyle(color: t.colorScheme.error)),
              ],
              const SizedBox(height: 12),
              FilledButton(
                key: const Key('submit-decision'),
                style: isDestructive(_action)
                    ? FilledButton.styleFrom(backgroundColor: t.colorScheme.error, foregroundColor: t.colorScheme.onError)
                    : null,
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(l.submitDecision),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Last look before the action takes effect: the statement exactly as the
/// owner will get it. Terminate is irreversible for the owner (the channel
/// disappears), so it also requires typing the channel handle, the same
/// friction GitHub uses for deleting a repository.
class ConfirmDecisionDialog extends StatefulWidget {
  const ConfirmDecisionDialog({
    super.key,
    required this.actionLabel,
    required this.preview,
    required this.destructive,
    this.requiredHandle,
  });

  final String actionLabel;
  final String? preview;
  final bool destructive;
  final String? requiredHandle;

  @override
  State<ConfirmDecisionDialog> createState() => _ConfirmDecisionDialogState();
}

class _ConfirmDecisionDialogState extends State<ConfirmDecisionDialog> {
  final _typed = TextEditingController();

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  bool get _ok => widget.requiredHandle == null || _typed.text.trim() == widget.requiredHandle;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(l.confirmTitle(widget.actionLabel)),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.confirmBody),
              const SizedBox(height: 12),
              Text(l.previewTitle, style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              Text(widget.preview ?? l.previewDismiss, key: const Key('confirm-preview')),
              if (widget.requiredHandle != null) ...[
                const SizedBox(height: 16),
                TextField(
                  key: const Key('confirm-handle'),
                  controller: _typed,
                  autofocus: true,
                  decoration: InputDecoration(labelText: l.confirmTypeHandle(widget.requiredHandle!)),
                  onChanged: (_) => setState(() {}),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(l.cancel)),
        FilledButton(
          key: const Key('confirm-ok'),
          style: widget.destructive
              ? FilledButton.styleFrom(backgroundColor: scheme.error, foregroundColor: scheme.onError)
              : null,
          onPressed: _ok ? () => Navigator.of(context).pop(true) : null,
          child: Text(l.confirm),
        ),
      ],
    );
  }
}
