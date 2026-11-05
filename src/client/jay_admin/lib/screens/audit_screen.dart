import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api/models.dart';
import '../app.dart';
import '../ui/format.dart';
import '../ui/widgets.dart';
import 'queue_screen.dart';

/// Append-only decision log (contract 4.8) with CSV export. Rows are
/// read-only on purpose: a decision is never edited, only followed by another
/// one (e.g. restore after suspend).
class AuditScreen extends StatefulWidget {
  const AuditScreen({super.key});

  static const pageSize = 100;

  /// Upper bound of CSV pages fetched for one export (100 rows each).
  static const maxCsvPages = 50;

  @override
  State<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends State<AuditScreen> {
  final _items = <Decision>[];
  bool _loading = true;
  bool _hasMore = false;
  bool _exporting = false;
  Object? _error;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _load();
    }
  }

  Future<void> _load({bool more = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await AdminScope.of(context).api.decisions(
        before: more && _items.isNotEmpty ? _items.last.createdAt : null,
        limit: AuditScreen.pageSize,
      );
      if (!mounted) return;
      setState(() {
        if (!more) _items.clear();
        _items.addAll(page);
        _hasMore = page.length >= AuditScreen.pageSize;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// Pages through `format=csv` with the same `before` cursor as the JSON
  /// list and joins the pages, keeping the header row only once. WHY not one
  /// request: the contract caps `limit` at 100.
  Future<void> _export() async {
    final scope = AdminScope.of(context);
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _exporting = true);
    try {
      final out = BytesBuilder();
      DateTime? before;
      for (var page = 0; page < AuditScreen.maxCsvPages; page++) {
        var csv = utf8.decode(await scope.api.decisionsCsv(before: before, limit: AuditScreen.pageSize));
        if (page > 0) {
          // Drop the repeated header. Only the header line is cut: data rows
          // may contain quoted line breaks (multi-line explanations), so the
          // CSV is never split into lines here.
          final nl = csv.indexOf('\n');
          csv = nl < 0 ? '' : csv.substring(nl + 1);
        }
        if (csv.isNotEmpty && !csv.endsWith('\n')) csv = '$csv\r\n';
        out.add(utf8.encode(csv));
        // The JSON page with the same cursor tells whether there is another
        // page and where it starts, without parsing CSV quoting rules.
        final json = await scope.api.decisions(before: before, limit: AuditScreen.pageSize);
        if (json.length < AuditScreen.pageSize) break;
        before = json.last.createdAt;
      }
      final stamp = DateTime.now().toUtc().toIso8601String().substring(0, 10);
      scope.browser.download('jay-moderation-decisions-$stamp.csv', out.takeBytes(), 'text/csv');
      messenger.showSnackBar(SnackBar(content: Text(l.auditExported)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(errorMessage(l, e))));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Text(l.navAudit, style: Theme.of(context).textTheme.titleLarge),
              const Spacer(),
              FilledButton.tonalIcon(
                key: const Key('export-csv'),
                onPressed: _exporting ? null : _export,
                icon: const Icon(Icons.download),
                label: Text(l.auditExportCsv),
              ),
            ],
          ),
        ),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _body() {
    if (_error != null && _items.isEmpty) return ErrorView(error: _error!, onRetry: _load);
    if (_loading && _items.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_items.isEmpty) return Center(child: Text(context.l10n.auditEmpty));
    final loc = context.l10n;
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              key: const Key('audit-table'),
              columns: [
                DataColumn(label: Text(loc.auditWhen)),
                DataColumn(label: Text(loc.auditAction)),
                DataColumn(label: Text(loc.auditSubject)),
                DataColumn(label: Text(loc.auditGround)),
                DataColumn(label: Text(loc.auditExplanation)),
                DataColumn(label: Text(loc.auditReports), numeric: true),
                DataColumn(label: Text(loc.auditOperator)),
              ],
              rows: [
                for (final d in _items)
                  DataRow(
                    cells: [
                      DataCell(Text(formatDateTime(context, d.createdAt))),
                      DataCell(Text(actionLabel(loc, d.action))),
                      DataCell(
                        Text(d.postId == null ? d.channelId : '${d.channelId} / ${d.postId}'),
                        onTap: () => context.go(caseLocation(d.channelId, postId: d.postId)),
                      ),
                      DataCell(Text(groundShort(loc, d))),
                      DataCell(
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 360),
                          child: Text(d.explanation, maxLines: 3, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                      DataCell(Text('${d.reportCount}')),
                      DataCell(Text(d.operatorAccountId)),
                    ],
                  ),
              ],
            ),
          ),
          if (_hasMore)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: OutlinedButton(
                  onPressed: _loading ? null : () => _load(more: true),
                  child: Text(loc.loadMore),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
