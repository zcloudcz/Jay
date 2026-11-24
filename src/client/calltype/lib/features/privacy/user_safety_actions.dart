import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/network/user_safety_api.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import 'block_controller.dart';

// Block and report a user (spec 2026-11-14-go-live A7-A9). Entry points: the
// 1:1 chat menu, the group member menu and the menu of a received message.

/// Asks, then blocks [id] (an identity or one of its devices). Returns true
/// when the person is blocked afterwards.
Future<bool> confirmAndBlockUser(
  BuildContext context, {
  required String id,
  required String name,
}) async {
  final l10n = context.l10n;
  final blocks = context.read<BlockController>();
  final messenger = ScaffoldMessenger.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.userBlockConfirmTitle(name)),
      content: Text(l10n.userBlockConfirmBody(name)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          key: const ValueKey('user-block-confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(l10n.userBlock),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  try {
    await blocks.block(id);
    messenger.showSnackBar(SnackBar(content: Text(l10n.userBlocked(name))));
    return true;
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.userBlockFailed)));
    return false;
  }
}

/// Lifts a block (no confirmation: it is the undo of a confirmed action).
Future<void> unblockUser(
  BuildContext context, {
  required String id,
  required String name,
}) async {
  final l10n = context.l10n;
  final blocks = context.read<BlockController>();
  final messenger = ScaffoldMessenger.of(context);
  try {
    await blocks.unblock(id);
    messenger.showSnackBar(SnackBar(content: Text(l10n.userUnblocked(name))));
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.userBlockFailed)));
  }
}

/// What the report form returns.
class _UserReportInput {
  const _UserReportInput(
    this.category,
    this.reason,
    this.email,
    this.goodFaith,
    this.attach,
  );
  final String category;
  final String reason;
  final String? email;
  final bool goodFaith;
  final bool attach;
}

/// Report form for a person: the channel report fields (category, reason,
/// good faith and contact e-mail for illegal content) plus the explicit
/// choice to attach [evidence]: the server cannot read end-to-end encrypted
/// chats, so the texts are only sent when the user ticks it (spec D7).
/// [attachByDefault] is true for a report started from one message.
Future<void> showReportUserDialog(
  BuildContext context, {
  required String deviceId,
  required String name,
  String? groupId,
  List<ReportEvidence> evidence = const [],
  bool attachByDefault = false,
}) async {
  final l10n = context.l10n;
  final api = context.read<ApiClient>();
  final blocks = context.read<BlockController>();
  final messenger = ScaffoldMessenger.of(context);
  final input = await showDialog<_UserReportInput>(
    context: context,
    builder: (_) => _UserReportDialog(
      name: name,
      evidenceCount: evidence.length,
      attachByDefault: attachByDefault && evidence.isNotEmpty,
    ),
  );
  if (input == null) return;
  try {
    final number = await api.reportUser(
      deviceId,
      reason: input.reason,
      category: input.category,
      contactEmail: input.email,
      goodFaith: input.goodFaith,
      groupId: groupId,
      messages: input.attach ? evidence : const [],
    );
    final blocked = blocks.isBlocked(deviceId);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          number > 0
              ? l10n.userReportReceipt('$number')
              : l10n.channelReportSent,
        ),
        // Reporting and blocking go together more often than not.
        action: blocked || !context.mounted
            ? null
            : SnackBarAction(
                label: l10n.userBlock,
                onPressed: () {
                  if (context.mounted) {
                    confirmAndBlockUser(context, id: deviceId, name: name);
                  }
                },
              ),
      ),
    );
  } catch (error) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          apiErrorCode(error) == 'report_limit_reached'
              ? l10n.userReportLimit
              : l10n.userReportFailed,
        ),
      ),
    );
  }
}

class _UserReportDialog extends StatefulWidget {
  const _UserReportDialog({
    required this.name,
    required this.evidenceCount,
    required this.attachByDefault,
  });

  final String name;
  final int evidenceCount;
  final bool attachByDefault;

  @override
  State<_UserReportDialog> createState() => _UserReportDialogState();
}

class _UserReportDialogState extends State<_UserReportDialog> {
  // Plain strings, not TextEditingControllers (same reason as the channel
  // report dialog: a controller would be disposed under the exit animation).
  String _category = 'terms';
  String _reason = '';
  String _email = '';
  bool _goodFaith = false;
  late bool _attach = widget.attachByDefault;

  bool get _illegal => _category == 'illegal';
  bool get _emailOk => _email.trim().isEmpty || _email.contains('@');
  bool get _canSubmit =>
      _reason.trim().isNotEmpty && (!_illegal || (_goodFaith && _emailOk));

  String _categoryLabel(AppLocalizations l10n, String category) =>
      switch (category) {
        'illegal' => l10n.channelReportCategoryIllegal,
        'spam' => l10n.channelReportCategorySpam,
        _ => l10n.userReportCategoryTerms,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(l10n.userReportTitle(widget.name)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.channelReportCategoryLabel,
              style: theme.textTheme.labelLarge,
            ),
            RadioGroup<String>(
              groupValue: _category,
              onChanged: (value) =>
                  setState(() => _category = value ?? _category),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final category in const ['terms', 'spam', 'illegal'])
                    RadioListTile<String>(
                      key: Key('user-report-category-$category'),
                      value: category,
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(_categoryLabel(l10n, category)),
                    ),
                ],
              ),
            ),
            TextField(
              key: const Key('user-report-reason'),
              onChanged: (v) => setState(() => _reason = v),
              maxLength: 1000,
              minLines: 1,
              maxLines: 4,
              decoration: InputDecoration(
                labelText: l10n.channelReportReasonLabel,
                helperText: l10n.userReportReasonHelper,
                helperMaxLines: 3,
              ),
            ),
            if (widget.evidenceCount > 0) ...[
              CheckboxListTile(
                key: const Key('user-report-attach'),
                value: _attach,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(l10n.userReportAttach(widget.evidenceCount)),
                subtitle: Text(l10n.userReportAttachHelp),
                onChanged: (v) => setState(() => _attach = v ?? false),
              ),
            ],
            if (_illegal) ...[
              CheckboxListTile(
                key: const Key('user-report-good-faith'),
                value: _goodFaith,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(l10n.channelReportGoodFaith),
                onChanged: (v) => setState(() => _goodFaith = v ?? false),
              ),
              TextField(
                key: const Key('user-report-email'),
                onChanged: (v) => setState(() => _email = v),
                keyboardType: TextInputType.emailAddress,
                maxLength: 254,
                decoration: InputDecoration(
                  labelText: l10n.channelReportEmailLabel,
                  helperText: l10n.channelReportEmailHelper,
                  helperMaxLines: 3,
                  errorText: _emailOk ? null : l10n.channelReportEmailInvalid,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          key: const Key('user-report-submit'),
          onPressed: _canSubmit
              ? () => Navigator.of(context).pop(
                  _UserReportInput(
                    _category,
                    _reason.trim(),
                    _illegal && _email.trim().isNotEmpty ? _email.trim() : null,
                    _illegal && _goodFaith,
                    _attach,
                  ),
                )
              : null,
          child: Text(l10n.channelReportSubmit),
        ),
      ],
    );
  }
}
