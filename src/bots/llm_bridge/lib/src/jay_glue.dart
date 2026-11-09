// The ONLY file of this package that touches the bot runtime (same split
// as a2a_bridge): everything else is unit-tested without a hub.
import 'package:calltype_bot/calltype_bot.dart';

import 'access.dart';
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

/// Publishes the "/" menu and the server inbound policy, then starts
/// answering through [bridge].
///
/// [allowedIds]: owner device id (lower-case) -> handle, from
/// `resolveAllowedHandles`.
///
/// Who is answered (spec 2026-11-09-bot-access, see [LlmAccess]): owners
/// everywhere; with [groupReplies] `members` any human member of a group
/// that has an owner in it; other bots only in groups, under the group's
/// bot-talk setting with an owner as member, capped by [peerTurnsCap].
/// Everyone else is dropped by the runtime BEFORE decryption.
Future<void> runJayGlue(
  CallTypeBot bot, {
  required LlmBridge bridge,
  required Map<String, String> allowedIds,
  GroupReplies groupReplies = GroupReplies.members,
  int peerTurnsCap = 50,
  String? inbound,
  DateTime Function()? now,
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
  // A3: the server keeps strangers and owner-less groups away too.
  await publishInboundPolicy(
    bot,
    owners: allowedIds.values,
    inbound: inbound,
    log: log,
  );

  final access = LlmAccess(
    owners: allowedIds,
    groupReplies: groupReplies,
    botTalk: BotTalkPolicy(
      selfDeviceId: bot.deviceId,
      ownerIds: allowedIds.keys.toSet(),
      turnsCap: peerTurnsCap,
      ownerRule: OwnerRule.member,
      now: now,
    ),
  );

  Future<void> handle(BotMessage message) async {
    GroupInfo? group;
    final groupId = message.groupId;
    if (groupId != null) {
      try {
        group = await bot.group(groupId);
      } catch (e) {
        log('Group $groupId unreadable, message dropped: $e');
        return;
      }
    }
    switch (access.decide(message.senderId, group)) {
      case Ignore():
        return;
      case BotLimitNotice():
        // Unquoted on purpose (same as hermes_bridge): a quote addresses
        // the other bot, which would count the notice as one more turn.
        await bot.send(to: groupId!, text: BridgeTexts.botLimit);
        return;
      case Answer(:final label):
        await bridge.handle(
          conversationId: message.conversationId,
          text: message.text,
          sink: _MessageSink(message),
          senderLabel: label,
        );
    }
  }

  // Reactions: no handler is set, so the runtime acknowledges and ignores
  // them (spec B2).
  await bot.onMessage(
    handle,
    allowSender: access.allowSender,
    // WHY a group lookup before decryption: only for senders that are not
    // owners, cached per group and dropped on the server's group hints.
    allowGroupSender: (id, groupId) async =>
        access.admitGroupSender(await bot.group(groupId), id),
  );
}
