import 'package:drift/drift.dart';

import 'package:calltype_core/storage/database.dart';
import '../chat/polls.dart';
import '../media/media_message.dart';

/// One search hit: the [message], the searchable [text] it was found in,
/// and where the match is in [text].
class SearchHit {
  const SearchHit({
    required this.message,
    required this.text,
    required this.matchStart,
    required this.matchLength,
  });

  final Message message;
  final String text;
  final int matchStart;
  final int matchLength;
}

/// The result of [searchMessages]; [limited] = cut at the limit.
class SearchResults {
  const SearchResults(this.hits, {required this.limited});
  final List<SearchHit> hits;
  final bool limited;
}

/// Message types whose text is searched (spec 2026-11-08-chat-extras).
/// Inline files are not: their body is base64 data.
const searchableTypes = ['text', pollMessageType, 'media'];

/// Searches the local history (the server has no plaintext), newest first.
///
/// WHY a scan in Dart instead of SQL `LIKE` or FTS5: `LIKE` folds case for
/// ASCII only and a leading `%` cannot use an index anyway, and FTS5 would
/// need a migration, triggers for edit / delete and a web sqlite build that
/// has it. Matching here ignores case and Latin diacritics. Pages of
/// [pageSize] rows keep memory flat; it stops after [limit] hits.
Future<SearchResults> searchMessages(
  AppDatabase db,
  String query, {
  String? conversationId,
  int limit = 200,
  int pageSize = 500,
}) async {
  final needle = foldForSearch(query.trim());
  if (needle.isEmpty) return const SearchResults([], limited: false);
  final hits = <SearchHit>[];
  for (var offset = 0; ; offset += pageSize) {
    final query = db.select(db.messages)
      ..where((m) => m.type.isIn(searchableTypes))
      ..where((m) => m.deleted.equals(false))
      ..where((m) => m.body.isNotNull())
      ..orderBy([
        (m) => OrderingTerm.desc(m.createdAt),
        (m) => OrderingTerm.desc(m.rowId),
      ])
      ..limit(pageSize, offset: offset);
    if (conversationId != null) {
      query.where((m) => m.conversationId.equals(conversationId));
    }
    final rows = await query.get();
    for (final message in rows) {
      final text = searchableText(message);
      if (text == null) continue;
      final index = foldForSearch(text).indexOf(needle);
      if (index < 0) continue;
      hits.add(
        SearchHit(
          message: message,
          text: text,
          matchStart: index,
          matchLength: needle.length,
        ),
      );
      if (hits.length >= limit) return SearchResults(hits, limited: true);
    }
    if (rows.length < pageSize) return SearchResults(hits, limited: false);
  }
}

/// The text of [message] that search looks at; null when nothing.
String? searchableText(Message message) {
  final body = message.body;
  if (body == null || message.deleted) return null;
  switch (message.type) {
    case 'text':
      return body;
    case pollMessageType:
      final poll = PollPayload.tryDecode(body);
      return poll == null
          ? null
          : ['📊 ${poll.question}', ...poll.options].join('\n');
    case 'media':
      return MediaInfo.tryDecode(body)?.caption;
  }
  return null;
}

/// Lower case without Latin diacritics, ONE code unit per code unit so a
/// match index in the folded text is the same index in the original.
String foldForSearch(String text) {
  final out = StringBuffer();
  for (final unit in text.codeUnits) {
    final char = String.fromCharCode(unit);
    final lower = char.toLowerCase();
    final folded = _diacritics[lower] ?? lower;
    out.write(folded.length == 1 ? folded : char);
  }
  return out.toString();
}

/// A snippet of [hit] around the match: about [context] characters before
/// it, cut at a word start when possible. Returns the snippet and the match
/// position inside it.
({String text, int start, int length}) searchSnippet(
  SearchHit hit, {
  int context = 32,
  int maxLength = 160,
}) {
  final flat = hit.text.replaceAll('\n', ' ');
  var from = hit.matchStart - context;
  if (from <= 0) {
    from = 0;
  } else {
    final space = flat.indexOf(' ', from);
    if (space >= 0 && space < hit.matchStart) from = space + 1;
  }
  var to = from + maxLength;
  if (to < hit.matchStart + hit.matchLength) {
    to = hit.matchStart + hit.matchLength;
  }
  if (to > flat.length) to = flat.length;
  final prefix = from > 0 ? '…' : '';
  final suffix = to < flat.length ? '…' : '';
  return (
    text: '$prefix${flat.substring(from, to)}$suffix',
    start: prefix.length + hit.matchStart - from,
    length: hit.matchLength,
  );
}

/// Accented Latin letters (lower case) to their base letter.
const _diacritics = {
  'á': 'a', 'à': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a', 'ā': 'a', //
  'ă': 'a', 'ą': 'a', 'ç': 'c', 'ć': 'c', 'č': 'c', 'ď': 'd', 'đ': 'd', //
  'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e', 'ě': 'e', 'ē': 'e', 'ę': 'e', //
  'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i', 'ī': 'i', 'ı': 'i', 'ľ': 'l', //
  'ĺ': 'l', 'ł': 'l', 'ñ': 'n', 'ń': 'n', 'ň': 'n', 'ó': 'o', 'ò': 'o', //
  'ô': 'o', 'ö': 'o', 'õ': 'o', 'ő': 'o', 'ø': 'o', 'ō': 'o', 'ŕ': 'r', //
  'ř': 'r', 'ś': 's', 'š': 's', 'ș': 's', 'ş': 's', 'ť': 't', 'ț': 't', //
  'ţ': 't', 'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u', 'ů': 'u', 'ű': 'u', //
  'ū': 'u', 'ý': 'y', 'ÿ': 'y', 'ź': 'z', 'ż': 'z', 'ž': 'z', 'ğ': 'g', //
};
