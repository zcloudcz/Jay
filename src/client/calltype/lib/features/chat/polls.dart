import 'dart:convert';

import 'package:calltype_core/messaging/poll.dart';
import 'package:drift/drift.dart';

import 'package:calltype_core/storage/database.dart';

export 'package:calltype_core/messaging/poll.dart';

/// Stores [options] as the vote of [voterId] on [pollId] if it is newer
/// than (or as new as) the stored one: last writer wins per (poll, voter),
/// spec 2026-11-08-chat-extras. An empty [options] withdraws the vote.
/// Returns whether it was applied. Same tie rule as reactions.
Future<bool> applyVote(
  AppDatabase db, {
  required String pollId,
  required String voterId,
  required String conversationId,
  required List<int> options,
  required int votedAt,
}) async {
  final current = await voteOf(db, pollId, voterId);
  if (current != null) {
    // Never moved into another conversation by a later claim.
    if (current.conversationId != conversationId) return false;
    if (votedAt < current.votedAt) return false;
  }
  await db
      .into(db.pollVotes)
      .insertOnConflictUpdate(
        PollVotesCompanion.insert(
          pollId: pollId,
          voterId: voterId,
          conversationId: conversationId,
          options: jsonEncode(options),
          votedAt: votedAt,
        ),
      );
  return true;
}

/// The vote row of [voterId] on [pollId], or null.
Future<PollVote?> voteOf(AppDatabase db, String pollId, String voterId) =>
    (db.select(db.pollVotes)
          ..where((v) => v.pollId.equals(pollId) & v.voterId.equals(voterId)))
        .getSingleOrNull();

/// Removes every vote on [pollId] (the poll was deleted).
Future<void> deleteVotesOf(AppDatabase db, String pollId) =>
    (db.delete(db.pollVotes)..where((v) => v.pollId.equals(pollId))).go();

/// Live totals of one poll.
class PollResults {
  const PollResults({
    required this.poll,
    required this.votersByOption,
    required this.mine,
    required this.voterCount,
  });

  final PollPayload poll;

  /// Identity ids per option (same order as [PollPayload.options]), the
  /// earliest vote first.
  final List<List<String>> votersByOption;

  /// The option indexes the local user picked (empty = no vote).
  final List<int> mine;

  /// People with a current vote.
  final int voterCount;

  int countOf(int option) => votersByOption[option].length;

  /// The highest count of any option (for the bars); at least 1.
  int get maxCount {
    var max = 1;
    for (final voters in votersByOption) {
      if (voters.length > max) max = voters.length;
    }
    return max;
  }
}

/// Counts the [votes] of [poll]. Withdrawn votes and votes that do not fit
/// the poll (an index it does not have, several picks on a single-choice
/// poll: possible when the vote arrived first) are not counted.
PollResults tallyPoll(
  PollPayload poll,
  Iterable<PollVote> votes, {
  required String myId,
}) {
  final byOption = [for (final _ in poll.options) <String>[]];
  final sorted = votes.toList()..sort((a, b) => a.votedAt.compareTo(b.votedAt));
  final me = myId.toLowerCase();
  var mine = const <int>[];
  var voters = 0;
  for (final vote in sorted) {
    final options = decodeVoteOptions(vote.options);
    if (options.isEmpty || !voteFits(poll, options)) continue;
    voters++;
    for (final option in options) {
      byOption[option].add(vote.voterId);
    }
    if (vote.voterId.toLowerCase() == me) mine = options;
  }
  return PollResults(
    poll: poll,
    votersByOption: byOption,
    mine: mine,
    voterCount: voters,
  );
}
