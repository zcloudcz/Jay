/// Bot command list (`PUT/GET /devices/{id}/bot-commands`), see
/// docs/superpowers/specs/2026-11-05-agent-messaging-contract.md section 4.
library;

/// One "/" command a bot offers, public metadata like its display name.
class BotCommand {
  const BotCommand({required this.command, required this.description});

  /// `^[a-z0-9_]{1,32}$`, without the leading slash.
  final String command;

  /// 1..100 characters after trim.
  final String description;

  static final commandPattern = RegExp(r'^[a-z0-9_]{1,32}$');

  /// Same rules the server enforces; lets a sender fail early and lets the
  /// app skip a bad entry instead of trusting the server blindly.
  bool get isValid {
    final d = description.trim();
    return commandPattern.hasMatch(command) && d.isNotEmpty && d.length <= 100;
  }

  Map<String, dynamic> toJson() => {
    'command': command,
    'description': description,
  };

  /// Null for a malformed entry. WHY lenient: the list is display-only
  /// metadata; one bad row must not hide the others.
  static BotCommand? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final command = raw['command'];
    final description = raw['description'];
    if (command is! String || description is! String) return null;
    return BotCommand(command: command, description: description);
  }

  /// Reads `{"commands": [...]}`; anything else is an empty list.
  static List<BotCommand> listFromJson(Object? body) {
    final list = body is Map ? body['commands'] : null;
    if (list is! List) return const [];
    return [for (final row in list) ?BotCommand.fromJson(row)];
  }

  @override
  bool operator ==(Object other) =>
      other is BotCommand &&
      other.command == command &&
      other.description == description;

  @override
  int get hashCode => Object.hash(command, description);

  @override
  String toString() => '/$command: $description';
}
