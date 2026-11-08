import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:calltype_core/storage/database.dart';
import '../../l10n/l10n.dart';
import 'message_search.dart';

/// Message search (spec 2026-11-08-chat-extras): over every conversation,
/// or only [conversationId] when opened from a chat. Runs on this device
/// only; the server has no plaintext to search.
class SearchScreen extends StatefulWidget {
  const SearchScreen({
    super.key,
    required this.database,
    required this.myIdentityId,
    required this.conversationTitle,
    required this.senderName,
    required this.onOpen,
    this.conversationId,
    this.debounce = const Duration(milliseconds: 250),
  });

  final AppDatabase database;
  final String myIdentityId;

  /// Null = all conversations.
  final String? conversationId;
  final String Function(String conversationId) conversationTitle;

  /// Name of another person (contact / member label).
  final String Function(String senderId) senderName;

  /// A result was tapped.
  final void Function(SearchHit hit) onOpen;
  final Duration debounce;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _field = TextEditingController();
  Timer? _timer;
  SearchResults? _results;
  String _query = '';

  /// Bumped per search; an older search that finishes late is dropped.
  int _generation = 0;

  @override
  void dispose() {
    _timer?.cancel();
    _field.dispose();
    super.dispose();
  }

  void _changed(String value) {
    _timer?.cancel();
    _timer = Timer(widget.debounce, () => _search(value));
  }

  Future<void> _search(String value) async {
    final generation = ++_generation;
    final query = value.trim();
    if (query.isEmpty) {
      setState(() {
        _query = '';
        _results = null;
      });
      return;
    }
    final results = await searchMessages(
      widget.database,
      query,
      conversationId: widget.conversationId,
    );
    if (!mounted || generation != _generation) return;
    setState(() {
      _query = query;
      _results = results;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final results = _results;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          key: const ValueKey('search-field'),
          controller: _field,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: l10n.searchHint,
            border: InputBorder.none,
          ),
          onChanged: _changed,
          onSubmitted: (value) {
            _timer?.cancel();
            _search(value);
          },
        ),
      ),
      body: results == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(l10n.searchPrompt, textAlign: TextAlign.center),
              ),
            )
          : results.hits.isEmpty
          ? Center(child: Text(l10n.searchNoResults))
          : ListView.builder(
              key: ValueKey('search-results:$_query'),
              itemCount: results.hits.length + (results.limited ? 1 : 0),
              itemBuilder: (context, index) {
                if (index == results.hits.length) {
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      l10n.searchResultsLimited(results.hits.length),
                      textAlign: TextAlign.center,
                    ),
                  );
                }
                return _resultTile(context, results.hits[index]);
              },
            ),
    );
  }

  Widget _resultTile(BuildContext context, SearchHit hit) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final message = hit.message;
    final sender = message.senderId == widget.myIdentityId
        ? l10n.chatYou
        : widget.senderName(message.senderId);
    final title = widget.conversationId == null
        ? '${widget.conversationTitle(message.conversationId)} · $sender'
        : sender;
    final snippet = searchSnippet(hit);
    final local = message.createdAt.toLocal();
    final now = DateTime.now();
    final date =
        local.year == now.year &&
            local.month == now.month &&
            local.day == now.day
        ? DateFormat.Hm(l10n.localeName).format(local)
        : DateFormat.yMd(l10n.localeName).format(local);
    final style = theme.textTheme.bodyMedium;
    return ListTile(
      key: ValueKey('search-hit:${message.id}'),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text.rich(
        TextSpan(
          style: style,
          children: [
            TextSpan(text: snippet.text.substring(0, snippet.start)),
            TextSpan(
              text: snippet.text.substring(
                snippet.start,
                snippet.start + snippet.length,
              ),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            TextSpan(
              text: snippet.text.substring(snippet.start + snippet.length),
            ),
          ],
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(date, style: theme.textTheme.labelSmall),
      onTap: () => widget.onOpen(hit),
    );
  }
}
