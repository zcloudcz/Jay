/// Parsers for the agent-messaging payload keys (mentions, buttons, button
/// presses, edits), shared by the app and the bot runtime
/// (docs/superpowers/specs/2026-11-05-agent-messaging-contract.md, sections
/// 1 and 2).
///
/// WHY nothing here throws: every value comes out of a decrypted payload
/// written by ANOTHER client (maybe a newer, older or buggy one). A message
/// with a malformed extra key must still show its text, so invalid input
/// degrades to "absent" instead of failing the whole message.
library;

import 'dart:convert';

const maxActions = 8;
const maxMentions = 50;
const maxActionLabel = 40;
const maxActionId = 64;

/// Button ids are machine tokens (`approve:<run>:<request>:once`), never
/// free text, so a strict charset keeps them safe to log and to split.
final actionIdPattern = RegExp(r'^[A-Za-z0-9_.:-]{1,64}$');

/// One button under a bot message (`actions` entry).
class MessageButton {
  const MessageButton({required this.id, required this.label});

  final String id;
  final String label;

  /// True when [id] and [label] are within the wire limits. Senders check
  /// this before sending; receivers drop invalid entries (see [parseActions]).
  bool get isValid => _validId(id) && _validLabel(label);

  Map<String, dynamic> toJson() => {'id': id, 'label': label};

  @override
  bool operator ==(Object other) =>
      other is MessageButton && other.id == id && other.label == label;

  @override
  int get hashCode => Object.hash(id, label);

  @override
  String toString() => 'MessageButton($id, $label)';
}

/// A button press (`action` on a text message): which bot message, which button.
class ActionRef {
  const ActionRef({required this.messageId, required this.id});

  /// Id of the bot message that carried the button.
  final String messageId;

  /// The pressed button's [MessageButton.id].
  final String id;

  Map<String, dynamic> toJson() => {'messageId': messageId, 'id': id};

  @override
  bool operator ==(Object other) =>
      other is ActionRef && other.messageId == messageId && other.id == id;

  @override
  int get hashCode => Object.hash(messageId, id);

  @override
  String toString() => 'ActionRef($messageId, $id)';
}

bool _validId(Object? id) => id is String && actionIdPattern.hasMatch(id);

/// Length in characters as a user sees them (runes), so an emoji label is
/// not cut short by its UTF-16 surrogate pairs. A label that is only blanks
/// renders as an empty button and is refused.
bool _validLabel(Object? label) =>
    label is String &&
    label.trim().isNotEmpty &&
    label.runes.length <= maxActionLabel;

/// `mentions`: identity ids, lower-cased (GUIDs are compared lower-case
/// everywhere), deduplicated, at most [maxMentions]. Non-string entries are
/// skipped; anything that is not a list yields an empty list.
List<String> parseMentions(Object? raw) {
  if (raw is! List) return const [];
  final result = <String>[];
  final seen = <String>{};
  for (final entry in raw) {
    if (result.length >= maxMentions) break;
    if (entry is! String) continue;
    final id = entry.trim().toLowerCase();
    if (id.isEmpty || !seen.add(id)) continue;
    result.add(id);
  }
  return result;
}

/// `actions`: valid buttons only, at most [maxActions]. Invalid entries are
/// dropped one by one (the valid ones still render); duplicate ids keep the
/// first, because a press names only the id and must be unambiguous.
List<MessageButton> parseActions(Object? raw) {
  if (raw is! List) return const [];
  final result = <MessageButton>[];
  final ids = <String>{};
  for (final entry in raw) {
    if (result.length >= maxActions) break;
    if (entry is! Map) continue;
    final id = entry['id'];
    final label = entry['label'];
    if (!_validId(id) || !_validLabel(label)) continue;
    if (!ids.add(id as String)) continue;
    result.add(MessageButton(id: id, label: label as String));
  }
  return result;
}

/// `action`: null unless both the message id and a valid button id are there.
ActionRef? parseActionRef(Object? raw) {
  if (raw is! Map) return null;
  final messageId = raw['messageId'];
  final id = raw['id'];
  if (messageId is! String || messageId.trim().isEmpty) return null;
  if (!_validId(id)) return null;
  return ActionRef(messageId: messageId, id: id as String);
}

/// `editOf`: the target message id, or null when missing or not a string.
String? parseEditOf(Object? raw) =>
    raw is String && raw.trim().isNotEmpty ? raw : null;

/// Encodes buttons for the `messages.actionsJson` column: null for none, so
/// a message without buttons stores nothing.
String? encodeActionsJson(List<MessageButton> actions) =>
    actions.isEmpty ? null : jsonEncode([for (final a in actions) a.toJson()]);

/// Reads the `messages.actionsJson` column back; corrupt data = no buttons.
List<MessageButton> decodeActionsJson(String? json) {
  if (json == null || json.isEmpty) return const [];
  try {
    return parseActions(jsonDecode(json));
  } on FormatException {
    return const [];
  }
}
