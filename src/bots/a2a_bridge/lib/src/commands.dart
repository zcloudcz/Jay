import 'a2a_protocol.dart';

/// One entry of the bot's "/" menu (mirrors calltype_core's `BotCommand`;
/// kept separate so this file stays free of runtime imports and testable).
class A2aCommand {
  const A2aCommand(this.command, this.description);
  final String command;
  final String description;

  @override
  bool operator ==(Object other) =>
      other is A2aCommand &&
      other.command == command &&
      other.description == description;

  @override
  int get hashCode => Object.hash(command, description);

  @override
  String toString() => '/$command: $description';
}

/// Server rules for bot commands (contract section 4).
final commandPattern = RegExp(r'^[a-z0-9_]{1,32}$');
const maxCommands = 50;
const maxCommandDescription = 100;

/// Built-in command: forget the agent context of this conversation.
const resetCommand = 'reset';

/// `toolset.web` -> `toolset_web`, `Summarize-Doc!` -> `summarize_doc`.
/// Null when nothing usable is left.
///
/// WHY normalise instead of skipping invalid ids: A2A skill ids are free
/// text (dots, dashes, camelCase are common), while Jay commands must match
/// `^[a-z0-9_]{1,32}$`; dropping them would hide most skills.
String? normalizeCommand(String id) {
  var s = id.trim().toLowerCase().replaceAll(RegExp('[^a-z0-9_]+'), '_');
  s = s.replaceAll(RegExp('_+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
  if (s.length > 32) s = s.substring(0, 32).replaceAll(RegExp(r'_+$'), '');
  return commandPattern.hasMatch(s) ? s : null;
}

String _description(String text, String fallback) {
  var d = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (d.isEmpty) d = fallback;
  if (d.length > maxCommandDescription) {
    d = '${d.substring(0, maxCommandDescription - 3).trimRight()}...';
  }
  return d;
}

/// The command list published at start: `/reset` first, then one command
/// per card skill (deduplicated with a numeric suffix), at most
/// [maxCommands]. Also returns the command -> skill map for incoming use.
({List<A2aCommand> commands, Map<String, A2aSkill> skills}) commandsFromSkills(
  List<A2aSkill> skills,
) {
  final commands = [
    const A2aCommand(resetCommand, 'Start a new conversation with the agent'),
  ];
  final bySkill = <String, A2aSkill>{};
  for (final skill in skills) {
    if (commands.length >= maxCommands) break;
    final base = normalizeCommand(skill.id) ?? normalizeCommand(skill.name);
    if (base == null) continue;
    var command = base;
    for (var n = 2; commands.any((c) => c.command == command); n++) {
      final suffix = '_$n';
      final head = base.length + suffix.length > 32
          ? base.substring(0, 32 - suffix.length)
          : base;
      command = '$head$suffix';
    }
    commands.add(
      A2aCommand(command, _description(skill.description, skill.name)),
    );
    bySkill[command] = skill;
  }
  return (commands: commands, skills: bySkill);
}

/// `/cmd args`, `/cmd@CT-ABCD-EFGH args` -> (cmd, args). Null for normal
/// text. The `@handle` suffix is what the app inserts in groups.
({String command, String args})? parseSlashCommand(String text) {
  final m = RegExp(
    r'^/([A-Za-z0-9_]{1,32})(?:@[A-Za-z0-9-]+)?(?:\s+([\s\S]*))?$',
  ).firstMatch(text.trim());
  if (m == null) return null;
  return (command: m.group(1)!.toLowerCase(), args: (m.group(2) ?? '').trim());
}
