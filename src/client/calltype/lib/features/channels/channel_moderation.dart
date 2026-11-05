import 'package:calltype_core/network/channel_dtos.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/l10n.dart';
import 'channels_controller.dart';

// Channel moderation in the app (contract 2026-11-05-channel-moderation,
// section 7): report form with receipt, the reporter's own reports, the
// suspension banner and the statements of reasons for the channel team.
// The operator side lives in a separate web (src/client/jay_admin), never in
// the app.

/// Opens a web address outside the app. A variable so widget tests can
/// record the call instead of reaching the platform plugin.
@visibleForTesting
Future<bool> Function(Uri uri) channelUrlLauncher = (uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// Opens the channel rules (Czech page for a Czech UI, else English), at
/// [rule]'s anchor when given. A failure shows the address so the user can
/// still get there.
Future<void> openChannelRules(BuildContext context, {String? rule}) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  final url = channelRulesUrl(l10n.localeName, rule: rule);
  var opened = false;
  try {
    opened = await channelUrlLauncher(Uri.parse(url));
  } catch (_) {
    // No browser / plugin missing: fall through to the message.
  }
  if (!opened) {
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.channelLinkOpenFailed(url))),
    );
  }
}

/// "Channel rules" link button.
class ChannelRulesLink extends StatelessWidget {
  const ChannelRulesLink({super.key, this.rule, this.label});
  final String? rule;

  /// Overrides the default "Channel rules" text (e.g. "Rule K3").
  final String? label;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    icon: const Icon(Icons.gavel_rounded, size: 18),
    label: Text(label ?? context.l10n.channelRules),
    onPressed: () => openChannelRules(context, rule: rule),
  );
}

/// Role code -> text. Unknown future roles read as "admin" rather than raw.
String channelRoleLabel(AppLocalizations l10n, String role) => switch (role) {
  channelRoleOwner => l10n.channelRoleOwner,
  channelRolePublisher => l10n.channelRolePublisher,
  _ => l10n.channelRoleAdmin,
};

String _date(AppLocalizations l10n, DateTime value) =>
    DateFormat.yMMMd(l10n.localeName).add_Hm().format(value.toLocal());

/// Shown to EVERYONE on a suspended channel's profile and feed (design D8),
/// with the end date when the server sent one.
class ChannelSuspendedBanner extends StatelessWidget {
  const ChannelSuspendedBanner({super.key, this.until});
  final DateTime? until;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    return Container(
      key: const Key('channel-suspended-banner'),
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(
            Icons.pause_circle_outline_rounded,
            color: scheme.onErrorContainer,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              until == null
                  ? l10n.channelSuspended
                  : l10n.channelSuspendedUntil(_date(l10n, until!)),
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

/// What the report form returns.
class _ReportInput {
  const _ReportInput(this.category, this.reason, this.email, this.goodFaith);
  final String category;
  final String reason;
  final String? email;
  final bool goodFaith;
}

/// Report form (DSA Art. 16): category, reason, and for illegal content a
/// required good-faith statement plus an optional contact e-mail. Shared by
/// the feed (one post) and the profile (whole channel). The reporter stays
/// anonymous to the channel's admins; only the operator sees the report.
/// On success a snackbar shows the report number (the Art. 16(4) receipt).
Future<void> reportChannelDialog(
  BuildContext context,
  String channelId, {
  String? postId,
}) async {
  final controller = context.read<ChannelsController>();
  final messenger = ScaffoldMessenger.of(context);
  final l10n = context.l10n;
  final input = await showDialog<_ReportInput>(
    context: context,
    builder: (_) => _ReportDialog(isPost: postId != null),
  );
  if (input == null) return;
  try {
    final number = await controller.report(
      channelId,
      postId: postId,
      reason: input.reason,
      category: input.category,
      contactEmail: input.email,
      goodFaith: input.goodFaith,
    );
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          // 0 = a server without receipts: no number to show.
          number > 0
              ? l10n.channelReportReceipt('$number')
              : l10n.channelReportSent,
        ),
      ),
    );
  } catch (error) {
    // Notably the daily report budget (429 report_limit_reached).
    messenger.showSnackBar(
      SnackBar(content: Text(channelErrorMessage(l10n, error))),
    );
  }
}

class _ReportDialog extends StatefulWidget {
  const _ReportDialog({required this.isPost});
  final bool isPost;

  @override
  State<_ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<_ReportDialog> {
  // Plain strings, not TextEditingControllers: a controller would have to be
  // disposed while the dialog's exit animation still uses it.
  String _category = 'terms';
  String _reason = '';
  String _email = '';
  bool _goodFaith = false;

  bool get _illegal => _category == 'illegal';

  /// Same rule as the server (`invalid_contact`): optional, but if given it
  /// must at least look like an address.
  bool get _emailOk => _email.trim().isEmpty || _email.contains('@');

  bool get _canSubmit =>
      _reason.trim().isNotEmpty && (!_illegal || (_goodFaith && _emailOk));

  String _categoryLabel(AppLocalizations l10n, String category) =>
      switch (category) {
        'illegal' => l10n.channelReportCategoryIllegal,
        'spam' => l10n.channelReportCategorySpam,
        _ => l10n.channelReportCategoryTerms,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(
        widget.isPost ? l10n.channelReportPost : l10n.channelReportChannel,
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.channelReportCategoryLabel,
              style: Theme.of(context).textTheme.labelLarge,
            ),
            RadioGroup<String>(
              groupValue: _category,
              onChanged: (value) =>
                  setState(() => _category = value ?? _category),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final category in channelReportCategories)
                    RadioListTile<String>(
                      key: Key('report-category-$category'),
                      value: category,
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(_categoryLabel(l10n, category)),
                    ),
                ],
              ),
            ),
            TextField(
              key: const Key('report-reason'),
              onChanged: (v) => setState(() => _reason = v),
              maxLength: 500,
              minLines: 1,
              maxLines: 4,
              decoration: InputDecoration(
                labelText: l10n.channelReportReasonLabel,
                helperText: l10n.channelReportReasonHelper,
                // Translations are longer than the English line.
                helperMaxLines: 3,
              ),
            ),
            if (_illegal) ...[
              CheckboxListTile(
                key: const Key('report-good-faith'),
                value: _goodFaith,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(l10n.channelReportGoodFaith),
                onChanged: (v) => setState(() => _goodFaith = v ?? false),
              ),
              TextField(
                key: const Key('report-email'),
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
            const ChannelRulesLink(),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: _canSubmit
              ? () => Navigator.of(context).pop(
                  _ReportInput(
                    _category,
                    _reason.trim(),
                    // The e-mail is asked for only with illegal content; a
                    // value typed before switching category is not sent.
                    _illegal && _email.trim().isNotEmpty ? _email.trim() : null,
                    _illegal && _goodFaith,
                  ),
                )
              : null,
          child: Text(l10n.channelReportSubmit),
        ),
      ],
    );
  }
}

/// "Moderation" section of the channel profile for owner / admin /
/// publisher (DSA Art. 17 statement of reasons, design D6). Hidden when the
/// server answers with an error (e.g. a server without moderation).
class ChannelModerationSection extends StatefulWidget {
  const ChannelModerationSection({super.key, required this.channelId});
  final String channelId;

  @override
  State<ChannelModerationSection> createState() =>
      _ChannelModerationSectionState();
}

class _ChannelModerationSectionState extends State<ChannelModerationSection> {
  late final Future<List<ModerationStatement>> _statements = context
      .read<ChannelsController>()
      .moderation(widget.channelId);

  @override
  Widget build(BuildContext context) =>
      FutureBuilder<List<ModerationStatement>>(
        future: _statements,
        builder: (context, snapshot) {
          if (snapshot.hasError) return const SizedBox.shrink();
          final statements = snapshot.data;
          if (statements == null) return const SizedBox.shrink();
          final l10n = context.l10n;
          final theme = Theme.of(context);
          return Column(
            key: const Key('channel-moderation-section'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Divider(height: 32),
              Text(
                l10n.channelModerationTitle,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              if (statements.isEmpty)
                Text(l10n.channelModerationEmpty)
              else ...[
                for (final statement in statements)
                  _StatementCard(statement: statement),
                const SizedBox(height: 4),
                Text(
                  l10n.channelModerationRedress,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ],
          );
        },
      );
}

class _StatementCard extends StatelessWidget {
  const _StatementCard({required this.statement});
  final ModerationStatement statement;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final title = switch (statement.action) {
      'remove_post' => l10n.channelModerationRemovePost,
      'suspend_channel' => l10n.channelModerationSuspend,
      'terminate_channel' => l10n.channelModerationTerminate,
      'restore_channel' => l10n.channelModerationRestore,
      _ => l10n.channelModerationOther,
    };
    final rule = statement.rule;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleSmall),
            Text(
              _date(l10n, statement.createdAt),
              style: theme.textTheme.labelSmall,
            ),
            if (statement.suspendedUntil != null)
              Text(
                l10n.channelSuspendedUntil(
                  _date(l10n, statement.suspendedUntil!),
                ),
              ),
            if (rule != null && channelRuleIds.contains(rule))
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: ChannelRulesLink(
                  rule: rule,
                  label: l10n.channelModerationRule(rule),
                ),
              ),
            if (statement.legalGround != null)
              Text(l10n.channelModerationLegalGround(statement.legalGround!)),
            if (statement.explanation.isNotEmpty) ...[
              const SizedBox(height: 4),
              SelectableText(statement.explanation),
            ],
            const SizedBox(height: 4),
            Text(
              statement.basedOnReports
                  ? l10n.channelModerationBasedOnReports
                  : l10n.channelModerationOwnInitiative,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// "Reports I filed": every report of this device and what became of it
/// (DSA Art. 16(5): the reporter learns the outcome in the app).
class MyReportsScreen extends StatefulWidget {
  const MyReportsScreen({super.key});

  @override
  State<MyReportsScreen> createState() => _MyReportsScreenState();
}

class _MyReportsScreenState extends State<MyReportsScreen> {
  late Future<List<MyReport>> _reports = context
      .read<ChannelsController>()
      .myReports();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.channelMyReportsTitle)),
      body: FutureBuilder<List<MyReport>>(
        future: _reports,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      l10n.channelMyReportsFailed,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () => setState(() {
                        _reports = context
                            .read<ChannelsController>()
                            .myReports();
                      }),
                      child: Text(l10n.commonRetry),
                    ),
                  ],
                ),
              ),
            );
          }
          final reports = snapshot.data;
          if (reports == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (reports.isEmpty) {
            return Center(child: Text(l10n.channelMyReportsEmpty));
          }
          return ListView.builder(
            itemCount: reports.length,
            itemBuilder: (context, index) =>
                _ReportTile(report: reports[index]),
          );
        },
      ),
    );
  }
}

class _ReportTile extends StatelessWidget {
  const _ReportTile({required this.report});
  final MyReport report;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final (status, color) = switch (report.status) {
      'dismissed' => (l10n.channelReportStatusDismissed, scheme.outline),
      'actioned' => (l10n.channelReportStatusActioned, scheme.primary),
      _ => (l10n.channelReportStatusOpen, scheme.tertiary),
    };
    final category = switch (report.category) {
      'illegal' => l10n.channelReportCategoryIllegal,
      'spam' => l10n.channelReportCategorySpam,
      _ => l10n.channelReportCategoryTerms,
    };
    final name = report.channelName.isNotEmpty
        ? report.channelName
        : report.channelHandle;
    final number = l10n.channelMyReportNumber('${report.reportId}');
    final created = _date(l10n, report.createdAt);
    return ListTile(
      key: ValueKey('report-${report.reportId}'),
      // A post report and a whole-channel report look different at a glance.
      leading: Icon(
        report.postId == null
            ? Icons.campaign_outlined
            : Icons.article_outlined,
      ),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [Text('$number · $category'), Text(created)],
      ),
      isThreeLine: true,
      trailing: Text(status, style: TextStyle(color: color)),
    );
  }
}
