/// Wire format of chat polls (docs/superpowers/specs/2026-11-08-chat-extras.md),
/// shared by the app and the bot runtime.
///
/// A poll travels as `type: text` with a fallback body plus a `poll` object
/// (old clients show the text); a vote is the control message
/// `type: poll-vote`. WHY nothing here throws on input from the wire: both are
/// written by ANOTHER client; an invalid one is ignored, never retried.
library;

import 'dart:convert';

/// Payload key of the poll object next to the fallback `body`.
const pollKey = 'poll';

/// Local `messages.type` of a received or sent poll.
const pollMessageType = 'poll';

/// Message payload `type` of a vote.
const pollVoteType = 'poll-vote';

const minPollOptions = 2;
const maxPollOptions = 10;
const maxPollQuestionLength = 300;
const maxPollOptionLength = 100;

/// Longest accepted poll id (message ids are UUIDs, 36 characters).
const maxPollIdLength = 64;

/// A poll: [question], [options] (2-10, distinct) and whether a voter may
/// pick several of them ([multiple]).
class PollPayload {
  const PollPayload({
    required this.question,
    required this.options,
    this.multiple = false,
  });

  final String question;
  final List<String> options;
  final bool multiple;

  /// Null when the values break a limit; the error names the field. Used by
  /// the composer to explain what is wrong before sending.
  static String? problemOf(
    String question,
    List<String> options, {
    bool multiple = false,
  }) {
    final q = question.trim();
    if (q.isEmpty || q.length > maxPollQuestionLength) return 'question';
    final trimmed = [for (final o in options) o.trim()];
    if (trimmed.length < minPollOptions || trimmed.length > maxPollOptions) {
      return 'options';
    }
    for (final o in trimmed) {
      if (o.isEmpty || o.length > maxPollOptionLength) return 'option';
    }
    if (trimmed.toSet().length != trimmed.length) return 'duplicate';
    return null;
  }

  /// Builds a trimmed poll; throws [ArgumentError] when it breaks a limit.
  factory PollPayload.create({
    required String question,
    required List<String> options,
    bool multiple = false,
  }) {
    final problem = problemOf(question, options, multiple: multiple);
    if (problem != null) throw ArgumentError('Invalid poll: $problem');
    return PollPayload(
      question: question.trim(),
      options: List.unmodifiable([for (final o in options) o.trim()]),
      multiple: multiple,
    );
  }

  /// The `poll` object of the wire payload.
  Map<String, Object?> toJson() => {
    'v': 1,
    'question': question,
    'options': options,
    'multiple': multiple,
  };

  /// Canonical local `messages.body` of a poll row.
  String encode() => jsonEncode(toJson());

  /// Parses the `poll` object of a received payload; null when invalid.
  static PollPayload? tryParse(Object? json) {
    if (json is! Map || json['v'] != 1) return null;
    final question = json['question'];
    final options = json['options'];
    final multiple = json['multiple'];
    if (question is! String || options is! List || multiple is! bool) {
      return null;
    }
    if (options.any((o) => o is! String)) return null;
    final list = options.cast<String>();
    // Untrimmed values that differ from their trimmed form are rejected, so
    // every client stores exactly what the sender showed.
    if (question.trim() != question || list.any((o) => o.trim() != o)) {
      return null;
    }
    if (problemOf(question, list, multiple: multiple) != null) return null;
    return PollPayload(
      question: question,
      options: List.unmodifiable(list),
      multiple: multiple,
    );
  }

  /// Parses a stored `messages.body`; null when it is not a poll.
  static PollPayload? tryDecode(String? body) {
    if (body == null || body.length > 8192) return null;
    try {
      return tryParse(jsonDecode(body));
    } on FormatException {
      return null;
    }
  }

  /// The text an old client shows instead of the poll. [updateHint] is the
  /// localized "update to vote" line of the sender's app.
  String fallbackText(String updateHint) =>
      ['📊 $question', for (final o in options) '• $o', updateHint].join('\n');

  @override
  bool operator ==(Object other) =>
      other is PollPayload &&
      other.question == question &&
      other.multiple == multiple &&
      _sameList(other.options, options);

  @override
  int get hashCode => Object.hash(question, multiple, Object.hashAll(options));

  @override
  String toString() => 'PollPayload($question, $options, multiple: $multiple)';
}

bool _sameList(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// One person's vote on [pollId]: the picked option indexes, sorted;
/// empty withdraws the vote.
class PollVotePayload {
  PollVotePayload({required this.pollId, required Iterable<int> options})
    : options = List.unmodifiable(options.toSet().toList()..sort());

  final String pollId;
  final List<int> options;

  bool get withdraws => options.isEmpty;

  /// The `body` string of the payload; throws [ArgumentError] for a value a
  /// receiver would drop.
  String encode() {
    if (!_validPollId(pollId)) {
      throw ArgumentError.value(pollId, 'pollId', 'invalid message id');
    }
    if (!validVoteOptions(options)) {
      throw ArgumentError.value(options, 'options', 'invalid option indexes');
    }
    return jsonEncode({'pollId': pollId, 'options': options});
  }

  /// Parses a received `body`; null when it is not a valid vote.
  static PollVotePayload? decode(Object? body) {
    if (body is! String || body.length > 1024) return null;
    Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      return null;
    }
    if (json is! Map) return null;
    final pollId = json['pollId'];
    final options = json['options'];
    if (pollId is! String || !_validPollId(pollId)) return null;
    if (options is! List || options.any((o) => o is! int)) return null;
    final list = options.cast<int>();
    if (list.toSet().length != list.length || !validVoteOptions(list)) {
      return null;
    }
    return PollVotePayload(pollId: pollId, options: list);
  }

  @override
  bool operator ==(Object other) =>
      other is PollVotePayload &&
      other.pollId == pollId &&
      _sameList(other.options, options);

  @override
  int get hashCode => Object.hash(pollId, Object.hashAll(options));

  @override
  String toString() => 'PollVotePayload($pollId, $options)';
}

/// Indexes 0-9, at most [maxPollOptions] of them.
bool validVoteOptions(Iterable<int> options) =>
    options.length <= maxPollOptions &&
    options.every((o) => o >= 0 && o < maxPollOptions);

/// Whether the stored [options] of a vote count for [poll]: every index
/// exists and a single-choice poll gets at most one. Checked when shown,
/// because a vote may arrive before its poll.
bool voteFits(PollPayload poll, List<int> options) =>
    options.every((o) => o >= 0 && o < poll.options.length) &&
    (poll.multiple || options.length <= 1);

/// Decodes the `options` column of a stored vote; empty for garbage.
List<int> decodeVoteOptions(String json) {
  try {
    final value = jsonDecode(json);
    if (value is List && value.every((o) => o is int)) {
      return value.cast<int>();
    }
  } on FormatException {
    // Fall through.
  }
  return const [];
}

bool _validPollId(String id) =>
    id.trim().isNotEmpty && id.length <= maxPollIdLength;
