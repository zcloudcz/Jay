import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../api/models.dart';
import '../app.dart';
import '../ui/format.dart';
import '../ui/widgets.dart';

/// Case URL for a subject; `from=queue` makes the case screen jump to the next
/// open case after a decision.
String caseLocation(String channelId, {String? postId, bool fromQueue = false}) {
  final q = {'postId': ?postId, if (fromQueue) 'from': 'queue'};
  // An empty map would still render a trailing '?'.
  return Uri(path: '/case/$channelId', queryParameters: q.isEmpty ? null : q).toString();
}

/// The main work surface: one row per subject (a channel, or one post), each
/// row saying WHY it is in the queue without opening it (review-queue
/// pattern): report count, categories, latest reason, channel reach, age and
/// prior actions. Filters live in the URL so a re-login returns to them.
class QueueScreen extends StatefulWidget {
  const QueueScreen({super.key, required this.status, this.category, this.subjectType});

  final String status;
  final String? category;
  final String? subjectType;

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> {
  final _items = <Subject>[];
  final _focus = FocusNode(debugLabel: 'queue');
  final _scroll = ScrollController();
  int _open = 0;
  int _resolved = 0;
  String? _next;
  bool _loading = true;
  Object? _error;
  int _selected = 0;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _load();
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    final api = AdminScope.of(context).api;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await api.reports(
        status: widget.status,
        category: widget.category,
        subjectType: widget.subjectType,
        cursor: more ? _next : null,
      );
      if (!mounted) return;
      setState(() {
        if (!more) _items.clear();
        _items.addAll(page.items);
        _open = page.openCount;
        _resolved = page.resolvedCount;
        _next = page.nextCursor;
        _loading = false;
      });
      if (!more) _focus.requestFocus();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  void _go({String? status, String? category, String? subjectType, bool clearCategory = false, bool clearSubject = false}) {
    final q = <String, String>{
      'status': status ?? widget.status,
      if (!clearCategory && (category ?? widget.category) != null) 'category': (category ?? widget.category)!,
      if (!clearSubject && (subjectType ?? widget.subjectType) != null) 'subjectType': (subjectType ?? widget.subjectType)!,
    };
    context.go(Uri(path: '/queue', queryParameters: q).toString());
  }

  void _openSelected() {
    if (_selected < 0 || _selected >= _items.length) return;
    final s = _items[_selected];
    context.go(caseLocation(s.channelId, postId: s.postId, fromQueue: true));
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _items.isEmpty) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.keyJ) {
      setState(() => _selected = (_selected + 1).clamp(0, _items.length - 1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyK) {
      setState(() => _selected = (_selected - 1).clamp(0, _items.length - 1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      _openSelected();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    const statuses = ['open', 'resolved', 'all'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Wrap(
            spacing: 16,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SegmentedButton<String>(
                key: const Key('queue-tabs'),
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: 'open', label: Text(l.tabOpen(_open), key: const Key('tab-open'))),
                  ButtonSegment(value: 'resolved', label: Text(l.tabResolved(_resolved), key: const Key('tab-resolved'))),
                  ButtonSegment(value: 'all', label: Text(l.tabAll, key: const Key('tab-all'))),
                ],
                selected: {statuses.contains(widget.status) ? widget.status : 'open'},
                onSelectionChanged: (s) => _go(status: s.first),
              ),
              DropdownButton<String>(
                key: const Key('filter-category'),
                value: widget.category ?? '',
                items: [
                  DropdownMenuItem(value: '', child: Text(l.filterAllCategories)),
                  for (final c in const ['illegal', 'terms', 'spam'])
                    DropdownMenuItem(value: c, child: Text(categoryLabel(l, c))),
                ],
                onChanged: (v) => v == null || v.isEmpty ? _go(clearCategory: true) : _go(category: v),
              ),
              DropdownButton<String>(
                key: const Key('filter-subject'),
                value: widget.subjectType ?? '',
                items: [
                  DropdownMenuItem(value: '', child: Text(l.filterAllSubjects)),
                  DropdownMenuItem(value: 'channel', child: Text(l.subjectChannel)),
                  DropdownMenuItem(value: 'post', child: Text(l.subjectPost)),
                ],
                onChanged: (v) => v == null || v.isEmpty ? _go(clearSubject: true) : _go(subjectType: v),
              ),
              Text(l.queueKeyboardHint, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _body() {
    if (_error != null && _items.isEmpty) return ErrorView(error: _error!, onRetry: _load);
    if (_loading && _items.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_items.isEmpty) return Center(child: Text(context.l10n.queueEmpty, key: const Key('queue-empty')));
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: ListView.builder(
        controller: _scroll,
        itemCount: _items.length + (_next != null ? 1 : 0),
        itemBuilder: (context, i) {
          if (i == _items.length) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: OutlinedButton(
                  onPressed: _loading ? null : () => _load(more: true),
                  child: Text(context.l10n.loadMore),
                ),
              ),
            );
          }
          return SubjectRow(
            key: ValueKey('subject-$i'),
            subject: _items[i],
            selected: i == _selected,
            onTap: () {
              setState(() => _selected = i);
              _openSelected();
            },
          );
        },
      ),
    );
  }
}

class SubjectRow extends StatelessWidget {
  const SubjectRow({super.key, required this.subject, required this.selected, required this.onTap});

  final Subject subject;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final s = subject;
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final waited = DateTime.now().toUtc().difference(s.firstReportedAt);
    final reason = s.latestReason.length > 160 ? '${s.latestReason.substring(0, 160)}...' : s.latestReason;
    return Material(
      color: selected ? scheme.primaryContainer.withValues(alpha: 0.5) : null,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: selected ? scheme.primary : Colors.transparent, width: 4),
              bottom: BorderSide(color: scheme.outlineVariant),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 110,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    StatusChip(
                      label: s.status == 'open' ? l.statusOpen : l.statusResolved,
                      color: s.status == 'open' ? scheme.primaryContainer : null,
                      onColor: s.status == 'open' ? scheme.onPrimaryContainer : null,
                    ),
                    const SizedBox(height: 6),
                    Text(l.reportCount(s.reportCount), style: t.titleSmall),
                    Text(s.subjectType == 'post' ? l.subjectPost : l.subjectChannel, style: t.labelSmall),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(s.channel.name, style: t.titleSmall),
                        Text(s.channel.handle, style: t.bodySmall),
                        Text(l.followers(s.channel.followerCount), style: t.bodySmall),
                        if (s.channel.deleted || s.channel.isSuspended) ChannelStatusChip(channel: s.channel),
                      ],
                    ),
                    const SizedBox(height: 4),
                    CategoryChips(categories: s.categories),
                    if (reason.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text('"$reason"', style: t.bodyMedium?.copyWith(fontStyle: FontStyle.italic), maxLines: 2, overflow: TextOverflow.ellipsis),
                    ],
                    if (s.post != null)
                      PostCard(channelId: s.channelId, post: s.post!, maxLines: 2, loadImage: false),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 150,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      l.waitingFor(formatAge(l, waited)),
                      style: t.bodySmall?.copyWith(
                        color: s.status == 'open' && waited > const Duration(days: 1) ? scheme.error : null,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l.priorDecisions(s.priorDecisions.length),
                      style: t.bodySmall?.copyWith(color: s.priorDecisions.isNotEmpty ? scheme.error : null),
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
