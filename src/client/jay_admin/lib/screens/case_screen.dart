import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api/models.dart';
import '../app.dart';
import '../ui/format.dart';
import '../ui/widgets.dart';
import 'decision_panel.dart';
import 'queue_screen.dart';

/// Case detail: context on the left (channel, the post among its neighbours,
/// all reports, history), decision panel on the right (research section 4,
/// screen 3). Also used for channels found via search, where there may be no
/// report at all (action on the operator's own initiative).
class CaseScreen extends StatefulWidget {
  const CaseScreen({super.key, required this.channelId, this.postId, this.fromQueue = false});

  final String channelId;
  final String? postId;
  final bool fromQueue;

  @override
  State<CaseScreen> createState() => _CaseScreenState();
}

class _CaseScreenState extends State<CaseScreen> {
  Future<CaseDetail>? _future;
  // Bumped after a decision so the panel starts empty for the next one.
  int _panelGeneration = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future ??= _fetch();
  }

  Future<CaseDetail> _fetch() =>
      AdminScope.of(context).api.subject(widget.channelId, postId: widget.postId);

  void _reload() => setState(() {
    _future = _fetch();
    _panelGeneration++;
  });

  Future<void> _afterDecision(Decision d) async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    if (!widget.fromQueue) {
      messenger.showSnackBar(SnackBar(content: Text(l.decisionSaved)));
      _reload();
      return;
    }
    // "After a decision go straight to the next case" (review-queue pattern):
    // the oldest open subject is the next one to handle.
    try {
      final page = await AdminScope.of(context).api.reports(status: 'open', limit: 2);
      final next = page.items.where((s) => !(s.channelId == widget.channelId && s.postId == widget.postId));
      if (next.isNotEmpty) {
        messenger.showSnackBar(SnackBar(content: Text(l.decisionSavedNext)));
        router.go(caseLocation(next.first.channelId, postId: next.first.postId, fromQueue: true));
        return;
      }
    } catch (_) {
      // Fall through to the queue; it shows its own error if the API is down.
    }
    messenger.showSnackBar(SnackBar(content: Text(l.decisionSavedDone)));
    router.go('/queue?status=open');
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<CaseDetail>(
      future: _future,
      builder: (context, snap) {
        if (snap.hasError) return ErrorView(error: snap.error!, onRetry: _reload);
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final d = snap.data!;
        final panel = DecisionPanel(
          key: ValueKey('panel-$_panelGeneration'),
          detail: d,
          postId: widget.postId,
          onDecided: _afterDecision,
        );
        return LayoutBuilder(
          builder: (context, c) {
            final left = _ContextColumn(detail: d, postId: widget.postId, fromQueue: widget.fromQueue);
            if (c.maxWidth >= 1000) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: ListView(padding: const EdgeInsets.all(16), children: [left])),
                  SizedBox(
                    width: 460,
                    child: ListView(padding: const EdgeInsets.fromLTRB(0, 16, 16, 16), children: [panel]),
                  ),
                ],
              );
            }
            return ListView(padding: const EdgeInsets.all(16), children: [left, const SizedBox(height: 16), panel]);
          },
        );
      },
    );
  }
}

class _ContextColumn extends StatelessWidget {
  const _ContextColumn({required this.detail, required this.postId, required this.fromQueue});

  final CaseDetail detail;
  final String? postId;
  final bool fromQueue;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = Theme.of(context).textTheme;
    final ch = detail.channel;

    // The reported post among its neighbours, oldest first like a feed.
    final posts = <PostSummary>[
      ...detail.context.where((p) => p.postId != detail.post?.postId),
      ?detail.post,
    ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (fromQueue)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () => context.go('/queue?status=open'),
              icon: const Icon(Icons.arrow_back),
              label: Text(l.backToQueue),
            ),
          ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.caseChannel, style: t.labelMedium),
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(ch.name, style: t.titleLarge),
                    SelectableText(ch.handle, key: const Key('case-handle')),
                    ChannelStatusChip(channel: ch),
                  ],
                ),
                if (ch.isSuspended && ch.suspendedUntil != null)
                  Text(l.suspendedUntil(formatDateTime(context, ch.suspendedUntil!))),
                if (ch.description.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(ch.description),
                ],
                const SizedBox(height: 8),
                Wrap(
                  spacing: 16,
                  children: [
                    Text(l.followers(ch.followerCount)),
                    Text(l.caseOwner(ch.ownerHandle)),
                    Text(l.caseCreated(formatDate(context, ch.createdAt))),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(postId != null ? l.caseContext : l.caseLatestPosts, style: t.titleMedium),
        if (posts.isEmpty) Text(l.caseNoPosts),
        for (final p in posts)
          PostCard(channelId: ch.channelId, post: p, highlighted: postId != null && p.postId == postId),
        const SizedBox(height: 16),
        Text(l.caseReports(detail.reports.length), style: t.titleMedium),
        if (detail.reports.isEmpty) Text(l.caseNoReports),
        for (final r in detail.reports) _ReportTile(report: r),
        const SizedBox(height: 16),
        Text(l.caseDecisions, style: t.titleMedium),
        if (detail.decisions.isEmpty) Text(l.caseNoDecisions),
        for (final dec in detail.decisions) DecisionTile(decision: dec),
      ],
    );
  }
}

class _ReportTile extends StatelessWidget {
  const _ReportTile({required this.report});

  final ReportItem report;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    // The reporter's identity is never shown (the API does not even send
    // it); only what the reporter chose to tell us.
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                CategoryChips(categories: {report.category: 1}),
                Text(formatDateTime(context, report.createdAt), style: Theme.of(context).textTheme.labelSmall),
                Text(reportStatusLabel(l, report.status), style: Theme.of(context).textTheme.labelSmall),
                if (report.goodFaith)
                  Text(l.reportGoodFaith, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.primary)),
              ],
            ),
            const SizedBox(height: 4),
            SelectableText(report.reason),
            if (report.contactEmail != null && report.contactEmail!.isNotEmpty)
              SelectableText(l.reportContact(report.contactEmail!), style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class DecisionTile extends StatelessWidget {
  const DecisionTile({super.key, required this.decision});

  final Decision decision;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final d = decision;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.gavel),
      title: Text('${actionLabel(l, d.action)}  ${groundShort(l, d)}'),
      subtitle: Text('${formatDateTime(context, d.createdAt)}\n${d.explanation}'),
      isThreeLine: true,
    );
  }
}
