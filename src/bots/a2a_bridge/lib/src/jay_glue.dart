// The ONLY file of this package that touches the bot runtime.
//
// It is written against the runtime API of contract section 5
// (docs/superpowers/specs/2026-11-05-agent-messaging-contract.md):
// `BotMessage.reply` returning `BotSentMessage`, `BotSentMessage.edit`,
// `CallTypeBot.setCommands` and calltype_core's `BotCommand`.
import 'package:a2a_bridge/a2a_bridge.dart';
import 'package:calltype_bot/calltype_bot.dart';

/// [ChatSink] over one incoming Jay message: replies go back into the
/// conversation it came from (the runtime quotes it in groups).
class _MessageSink implements ChatSink {
  _MessageSink(this._message);
  final BotMessage _message;

  @override
  Future<ProgressHandle> progress(String text) async =>
      _SentProgress(await _message.reply(text));

  @override
  Future<void> reply(String text) async {
    await _message.reply(text);
  }
}

class _SentProgress implements ProgressHandle {
  _SentProgress(this._sent);
  final BotSentMessage _sent;

  @override
  Future<void> update(String text) => _sent.edit(text);
}

/// Publishes the agent's skills as the bot's "/" menu and starts answering
/// messages of the allowed owners through [bridge].
///
/// [allowedIds]: owner device id (lower-case) -> handle, from
/// `resolveAllowedHandles`.
///
/// WHY only owners, also in groups, and never other bots: the agent behind
/// the bridge may hold tools and data of its operator; contract D9 gives
/// this bot the same allowlist model as the Hermes bridge, minus bot talk
/// (an A2A agent answering other bots in a loop is exactly what nobody
/// watches). Other senders are dropped by the runtime BEFORE decryption.
Future<void> runJayGlue(
  CallTypeBot bot, {
  required A2aBridge bridge,
  required Map<String, String> allowedIds,
  bool ackReactions = true,
  required void Function(String) log,
}) async {
  try {
    await bot.setCommands([
      for (final c in bridge.commands)
        BotCommand(command: c.command, description: c.description),
    ]);
  } catch (e) {
    // The menu is a convenience; the bot works without it (old server).
    log('Publishing bot commands failed: $e');
  }

  // Group context (spec 2026-11-13-group-topics T3): what the group said
  // between two owner turns, in memory.
  final context = GroupContextBuffer();

  Future<void> handle(BotMessage message) async {
    final owner = allowedIds[message.senderId.toLowerCase()];
    if (owner == null) return; // belt and braces; allowSender already said no
    final failed = await bridge.handle(
      conversationId: message.conversationId,
      text: message.text,
      sink: _MessageSink(message),
      // In a group several owners may talk to the same agent context.
      senderLabel: message.isGroup ? owner : null,
      groupTopic: message.groupTopic,
      groupTopicVersion: message.groupTopicVersion,
      groupContext: message.isGroup
          ? context.take(message.conversationId)
          : null,
    );
    if (failed) message.markFailed();
  }

  // Before onMessage, which connects.
  bot.onContext((message) async => context.addMessage(message));
  await bot.onMessage(
    handle,
    allowSender: (id) => allowedIds.containsKey(id.toLowerCase()),
    // The groups this bridge works for: an owner is a member. Only there
    // are other members' messages decrypted, for the topic and as context;
    // they never start a turn.
    servesGroup: (groupId) async => (await bot.group(
      groupId,
    )).members.any((m) => allowedIds.containsKey(m.deviceId.toLowerCase())),
    // Automatic (spec 2026-11-11-bot-ack-reactions R4): the allowlist above
    // already decided, so every message reaching [handle] gets 👀 and then
    // ✅ / 👍 / ❌. No model directive here: A2A agents do not know it.
    // Reactions get no handler, so they are acked and ignored (also other
    // bots' reactions: they never start a turn).
    ackReactions: ackReactions ? const AckReactions() : null,
  );
}
