import 'package:calltype_core/network/bot_dtos.dart';

/// Pure logic for the "/" command menu of chats with bots (agent messaging
/// contract sections 4 and 8). No Flutter imports, so it is unit-testable.

/// A bot in the current chat whose commands can be offered.
class CommandBot {
  const CommandBot({required this.deviceId, this.handle, this.name});

  /// The bot's device id, the key of `GET /devices/{id}/bot-commands`.
  final String deviceId;

  /// `CT-XXXX-XXXX`; needed in groups for the `/cmd@HANDLE` form.
  final String? handle;

  /// Shown next to the command in groups so the user knows which bot
  /// answers it.
  final String? name;
}

/// One row of the "/" menu.
class CommandSuggestion {
  const CommandSuggestion({
    required this.command,
    required this.description,
    required this.insert,
    this.botName,
  });

  /// Without the slash.
  final String command;
  final String description;

  /// What replaces the typed `/partial`: `/cmd ` in a 1:1 chat,
  /// `/cmd@HANDLE ` in a group.
  final String insert;

  /// Which bot offers it (groups only).
  final String? botName;
}

/// Returns the text typed after a `/` that opens the composer, while the
/// cursor is still in that first word; null otherwise.
///
/// WHY only at the very start: commands are a bot convention (Telegram) that
/// bots recognise only as the first word; a slash in the middle of a
/// sentence ("and/or") must not pop a menu up.
String? activeCommandQuery(String text, int cursor) {
  if (cursor < 1 || cursor > text.length || !text.startsWith('/')) {
    return null;
  }
  final typed = text.substring(1, cursor);
  if (typed.contains(RegExp(r'\s'))) return null;
  return typed;
}

/// The menu for [bots] with their [commands] (by bot device id). In a
/// [group] the command names its bot (`/cmd@HANDLE`): several bots may offer
/// the same command and a group bot answers only what is addressed to it.
List<CommandSuggestion> buildCommandSuggestions({
  required List<CommandBot> bots,
  required Map<String, List<BotCommand>> commands,
  required bool group,
}) {
  final result = <CommandSuggestion>[];
  for (final bot in bots) {
    // Without a handle a group command cannot be addressed; skip that bot
    // rather than insert a bare command every bot in the group would see.
    if (group && bot.handle == null) continue;
    for (final c in commands[bot.deviceId] ?? const <BotCommand>[]) {
      // The server validated the list, but the app does not trust a value
      // it inserts into what the user sends.
      if (!c.isValid) continue;
      result.add(
        CommandSuggestion(
          command: c.command,
          description: c.description.trim(),
          insert: group ? '/${c.command}@${bot.handle} ' : '/${c.command} ',
          botName: group ? (bot.name ?? bot.handle) : null,
        ),
      );
    }
  }
  return result;
}

/// Case-insensitive prefix match on the command name; empty = all.
List<CommandSuggestion> filterCommands(
  List<CommandSuggestion> all,
  String query,
) {
  // `/help@CT-...` typed by hand: only the command part filters.
  final needle = query.split('@').first.toLowerCase();
  if (needle.isEmpty) return all;
  return all.where((c) => c.command.startsWith(needle)).toList();
}

/// Per-bot cache of command lists, 10 minutes (contract section 4: there is
/// no hub hint when a bot changes its list, so clients re-read it after a
/// while). App-wide ([shared]) so reopening a chat does not refetch.
class BotCommandsCache {
  BotCommandsCache({
    this.ttl = const Duration(minutes: 10),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static final shared = BotCommandsCache();

  final Duration ttl;
  final DateTime Function() _now;
  final _entries = <String, ({DateTime at, List<BotCommand> commands})>{};

  /// The cached list of [botId], or [fetch] it. A failed fetch is not
  /// cached (the next "/" asks again) and yields an empty menu: the menu is
  /// a convenience, typing the command by hand always works.
  Future<List<BotCommand>> get(
    String botId,
    Future<List<BotCommand>> Function(String botId) fetch,
  ) async {
    final key = botId.toLowerCase();
    final cached = _entries[key];
    final now = _now();
    if (cached != null && now.difference(cached.at) < ttl) {
      return cached.commands;
    }
    try {
      final commands = await fetch(botId);
      _entries[key] = (at: now, commands: commands);
      return commands;
    } catch (_) {
      return const [];
    }
  }

  void clear() => _entries.clear();
}
