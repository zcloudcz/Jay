import '../../core/network/api_client.dart';
import '../../core/storage/database.dart';

/// Pure logic for @mention suggestions in group chats (no Flutter imports so
/// it is trivially unit-testable).

/// One row in the suggestion list.
class MentionCandidate {
  const MentionCandidate({
    required this.label,
    required this.token,
    this.detail,
    this.isBot = false,
    this.id,
  });

  /// The member's identity id, sent in the structured `mentions` list when
  /// the candidate is picked (contract section 8). Null = text only.
  final String? id;

  /// What the user sees (their own local name for the contact, if any).
  final String label;

  /// Secondary line, the member's handle.
  final String? detail;

  /// What is inserted after the `@`.
  final String token;
  final bool isBot;
}

/// The `@partial` word the cursor currently sits in.
class MentionQuery {
  const MentionQuery(this.start, this.query);

  /// Index of the `@` in the text.
  final int start;

  /// Text typed after the `@` (may be empty).
  final String query;
}

bool _isSpace(String ch) => ch.trim().isEmpty;

/// Returns the mention being typed at [cursor], or null.
///
/// The `@` must open the text or follow whitespace, so e-mail addresses
/// (`a@b.cz`) never trigger suggestions, and there must be no whitespace
/// between the `@` and the cursor.
MentionQuery? activeMentionQuery(String text, int cursor) {
  if (cursor < 0 || cursor > text.length) return null;
  for (var i = cursor - 1; i >= 0; i--) {
    final ch = text[i];
    if (_isSpace(ch)) return null;
    if (ch == '@') {
      if (i > 0 && !_isSpace(text[i - 1])) return null;
      return MentionQuery(i, text.substring(i + 1, cursor));
    }
  }
  return null;
}

/// Replaces the partial `@query` (from `q.start` to [cursor]) with
/// `@token ` and returns the new text plus the cursor after the space.
({String text, int cursor}) applyMention(
  String text,
  MentionQuery q,
  int cursor,
  String token,
) {
  final inserted = '@$token ';
  return (
    text: text.replaceRange(q.start, cursor, inserted),
    cursor: q.start + inserted.length,
  );
}

/// A suggestion the user picked: the inserted token and whom it means.
typedef PickedMention = ({String token, String id});

/// Identity ids of [picked] mentions whose `@token` is still in [text]
/// (the user may have deleted or retyped it after picking), deduplicated.
///
/// WHY a boundary on both sides: the same rule as [activeMentionQuery] (an
/// `@` opens the text or follows whitespace), and `@Hermes` must not count
/// inside `@HermesBackup`, which may be another member.
List<String> mentionedIds(String text, Iterable<PickedMention> picked) {
  final result = <String>[];
  for (final p in picked) {
    if (result.contains(p.id)) continue;
    final pattern = RegExp(
      '(?:^|\\s)@${RegExp.escape(p.token)}(?![\\p{L}\\p{N}_-])',
      unicode: true,
    );
    if (pattern.hasMatch(text)) result.add(p.id);
  }
  return result;
}

/// Case-insensitive "contains" on label, token and detail; empty = all.
List<MentionCandidate> filterMentions(
  List<MentionCandidate> all,
  String query,
) {
  final needle = query.toLowerCase();
  if (needle.isEmpty) return all;
  return all
      .where(
        (c) =>
            c.label.toLowerCase().contains(needle) ||
            c.token.toLowerCase().contains(needle) ||
            (c.detail?.toLowerCase().contains(needle) ?? false),
      )
      .toList();
}

Contact? _contactFor(List<Contact> contacts, String deviceId) {
  for (final c in contacts) {
    if (c.deviceId == deviceId) return c;
  }
  return null;
}

/// Builds the suggestion list for a group from the server's member list and
/// the local contacts.
List<MentionCandidate> buildMentionCandidates({
  required List<GroupMemberInfo> members,
  required List<Contact> contacts,
  required String myIdentityId,
}) {
  final result = <MentionCandidate>[];
  for (final member in members) {
    if (member.deviceId == myIdentityId) continue;
    final contact = _contactFor(contacts, member.deviceId);
    final handle = member.userHandle ?? contact?.userHandle;
    // Old server and not a contact: nothing a bot (or a person) could match.
    if (handle == null) continue;
    final serverName = member.displayName;
    result.add(
      MentionCandidate(
        // WHY the token is never the local contact name: bots match
        // `@<handle>` or `@<their OWN server display name>` (see mentionsBot
        // in calltype_bot). A name the user typed in "Rename" exists only on
        // this device, so inserting it would silently address nobody.
        token: serverName != null && serverName.isNotEmpty
            ? serverName
            : handle,
        label: contact?.displayName ?? serverName ?? handle,
        detail: handle,
        isBot: member.isBot || (contact?.isBot ?? false),
        id: member.deviceId,
      ),
    );
  }
  return result;
}

/// Whether [senderId] is a bot, by the group's member profiles or the local
/// contact flag. Decides whether a message's buttons are drawn: buttons from
/// a human are never shown (agent messaging design, security: phishing).
bool isBotSender(
  String senderId, {
  required List<GroupMemberInfo> members,
  required List<Contact> contacts,
}) {
  final id = senderId.toLowerCase();
  for (final m in members) {
    if (m.deviceId.toLowerCase() == id && m.isBot) return true;
  }
  for (final c in contacts) {
    if (c.deviceId.toLowerCase() == id && c.isBot) return true;
  }
  return false;
}

/// Name shown above another member's message in a group: the user's own name
/// for the contact, else the member's profile name, else a handle, else the
/// raw id.
String senderLabel(
  String senderId, {
  required List<GroupMemberInfo> members,
  required List<Contact> contacts,
}) {
  final contact = _contactFor(contacts, senderId);
  GroupMemberInfo? member;
  for (final m in members) {
    if (m.deviceId == senderId) member = m;
  }
  return contact?.displayName ??
      member?.displayName ??
      member?.userHandle ??
      contact?.userHandle ??
      senderId;
}
