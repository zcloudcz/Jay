import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api/models.dart';
import '../app.dart';
import '../ui/format.dart';
import '../ui/widgets.dart';

/// Counts at a glance (research section 4, screen 1). There is no push to the
/// operator (design D12), so this page is where new reports become visible.
class OverviewScreen extends StatefulWidget {
  const OverviewScreen({super.key});

  @override
  State<OverviewScreen> createState() => _OverviewScreenState();
}

class _OverviewScreenState extends State<OverviewScreen> {
  Future<AdminSummary>? _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future ??= AdminScope.of(context).api.summary();
  }

  void _reload() => setState(() {
    _future = AdminScope.of(context).api.summary();
  });

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return FutureBuilder<AdminSummary>(
      future: _future,
      builder: (context, snap) {
        if (snap.hasError) return ErrorView(error: snap.error!, onRetry: _reload);
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final s = snap.data!;
        final oldest = s.oldestOpenAt == null
            ? l.overviewNone
            : formatAge(l, DateTime.now().toUtc().difference(s.oldestOpenAt!));
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                _Metric(key: const Key('metric-open-reports'), label: l.overviewOpenReports, value: '${s.openReports}'),
                _Metric(key: const Key('metric-open-subjects'), label: l.overviewOpenSubjects, value: '${s.openSubjects}'),
                _Metric(key: const Key('metric-oldest'), label: l.overviewOldest, value: oldest, warn: s.oldestOpenAt != null && DateTime.now().toUtc().difference(s.oldestOpenAt!) > const Duration(days: 1)),
                _Metric(key: const Key('metric-suspended'), label: l.overviewSuspended, value: '${s.suspendedChannels}'),
                _Metric(key: const Key('metric-decisions'), label: l.overviewDecisions30, value: '${s.decisionsLast30Days}'),
              ],
            ),
            const SizedBox(height: 24),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton.icon(
                onPressed: () => context.go('/queue?status=open'),
                icon: const Icon(Icons.flag),
                label: Text(l.overviewOpenQueue),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({super.key, required this.label, required this.value, this.warn = false});

  final String label;
  final String value;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return SizedBox(
      width: 220,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: t.textTheme.labelMedium),
              const SizedBox(height: 8),
              Text(value, style: t.textTheme.headlineMedium?.copyWith(color: warn ? t.colorScheme.error : null)),
            ],
          ),
        ),
      ),
    );
  }
}
