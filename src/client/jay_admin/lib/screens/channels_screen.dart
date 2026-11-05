import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api/models.dart';
import '../app.dart';
import '../ui/format.dart';
import '../ui/widgets.dart';
import 'queue_screen.dart';

/// Channel search (contract 4.7): the entry point for acting without a report
/// and for restoring a suspended channel. Opening a result shows the same
/// case screen and decision panel as a reported channel.
class ChannelsScreen extends StatefulWidget {
  const ChannelsScreen({super.key, this.initialQuery = ''});

  final String initialQuery;

  @override
  State<ChannelsScreen> createState() => _ChannelsScreenState();
}

class _ChannelsScreenState extends State<ChannelsScreen> {
  late final _q = TextEditingController(text: widget.initialQuery);
  Future<List<ChannelSummary>>? _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_future == null && widget.initialQuery.trim().isNotEmpty) _future = _fetch();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<List<ChannelSummary>> _fetch() => AdminScope.of(context).api.channels(_q.text);

  void _search() {
    if (_q.text.trim().isEmpty) return;
    setState(() {
      _future = _fetch();
    });
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
              Expanded(
                child: TextField(
                  key: const Key('channels-query'),
                  controller: _q,
                  decoration: InputDecoration(
                    hintText: l.channelsSearchHint,
                    prefixIcon: const Icon(Icons.search),
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _search(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(key: const Key('channels-search'), onPressed: _search, child: Text(l.channelsSearch)),
            ],
          ),
        ),
        Expanded(
          child: _future == null
              ? Center(child: Text(l.channelsPrompt))
              : FutureBuilder<List<ChannelSummary>>(
                  future: _future,
                  builder: (context, snap) {
                    if (snap.hasError) return ErrorView(error: snap.error!, onRetry: _search);
                    if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                    final list = snap.data!;
                    if (list.isEmpty) return Center(child: Text(l.channelsEmpty));
                    return ListView.separated(
                      itemCount: list.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final c = list[i];
                        return ListTile(
                          key: ValueKey('channel-${c.channelId}'),
                          title: Text(c.name),
                          subtitle: Text(
                            '${c.handle}  ${l.followers(c.followerCount)}  ${l.caseOwner(c.ownerHandle)}'
                            '${c.isSuspended && c.suspendedUntil != null ? '\n${l.suspendedUntil(formatDateTime(context, c.suspendedUntil!))}' : ''}',
                          ),
                          trailing: ChannelStatusChip(channel: c),
                          onTap: () => context.go(caseLocation(c.channelId)),
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}
