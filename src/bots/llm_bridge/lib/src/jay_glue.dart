// The ONLY file of this package that touches the bot runtime (same split
// as a2a_bridge): everything else is unit-tested without a hub.
import 'package:calltype_bot/calltype_bot.dart';

import 'bridge.dart';
import 'history_store.dart';

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

/// Sends the one-time greeting (spec B4) to every owner that has not had
/// it yet, so the bot shows up in the owner's chat list without anyone
/// typing a handle. The marker is written only after a successful send: a
/// failed greeting is retried on the next start, a sent one never repeats.
Future<void> greetOwners({
  required Iterable<String> handles,
  required HistoryStore store,
  required Future<void> Function(String handle, String text) send,
  required String displayName,
  void Function(String) log = _noLog,
}) async {
  for (final handle in handles) {
    if (await store.greeted(handle)) continue;
    try {
      await send(handle, BridgeTexts.greeting(displayName));
      await store.markGreeted(handle);
      log('Greeting sent to $handle.');
    } catch (e) {
      log('Greeting to $handle failed ($e); will retry on the next start.');
    }
  }
}

void _noLog(String _) {}

/// Publishes the "/" menu and starts answering messages of the allowed
/// owners through [bridge].
///
/// [allowedIds]: owner device id (lower-case) -> handle, from
/// `resolveAllowedHandles`.
///
/// WHY only owners, also in groups, and never other bots: every answer is
/// paid from the owner's API key or subscription and the history is his
/// private conversation (spec, fail-closed access). Other senders are
/// dropped by the runtime BEFORE decryption.
Future<void> runJayGlue(
  CallTypeBot bot, {
  required LlmBridge bridge,
  required Map<String, String> allowedIds,
  required void Function(String) log,
}) async {
  try {
    await bot.setCommands([
      for (final c in botCommands)
        BotCommand(command: c.command, description: c.description),
    ]);
  } catch (e) {
    // The menu is a convenience; the bot works without it (old server).
    log('Publishing bot commands failed: $e');
  }

  Future<void> handle(BotMessage message) async {
    final owner = allowedIds[message.senderId.toLowerCase()];
    if (owner == null) return; // belt and braces; allowSender already said no
    await bridge.handle(
      conversationId: message.conversationId,
      text: message.text,
      sink: _MessageSink(message),
      senderLabel: message.isGroup ? owner : null,
    );
  }

  // Reactions: no handler is set, so the runtime acknowledges and ignores
  // them (spec B2).
  await bot.onMessage(
    handle,
    allowSender: (id) => allowedIds.containsKey(id.toLowerCase()),
  );
}
