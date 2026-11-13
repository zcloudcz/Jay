// The ONLY file of this package that touches the bot runtime (same split
// as a2a_bridge): everything else is unit-tested without a hub.
import 'package:calltype_bot/calltype_bot.dart';

import 'access.dart';
import 'bridge.dart';
import 'history_store.dart';
import 'images.dart';

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

  @override
  Future<void> replyFile(String path) async {
    await _message.replyFile(path);
  }
}

/// [IncomingFile] over a runtime attachment: the download and decryption
/// stay in calltype_bot (the app's MediaCipher), errors are mapped.
IncomingFile incomingFileOf(BotAttachment a) => IncomingFile(
  name: a.name,
  mime: a.mime,
  size: a.size,
  isImage: a.kind == MediaKind.image || a.mime.startsWith('image/'),
  caption: a.caption,
  read: (maxBytes) async {
    try {
      return await a.readBytes(maxBytes: maxBytes);
    } on BotMediaExpired {
      throw const IncomingFileExpired();
    } on BotMediaTooLarge {
      throw const IncomingFileTooLarge();
    }
  },
);

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
  int imageMaxBytes = defaultImageMaxBytes,
  DateTime Function()? now,
  bool ackReactions = true,
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

  /// The turn's outcome becomes the final acknowledgement reaction.
  void settle(BotMessage message, TurnOutcome outcome) {
    if (outcome.failed) message.markFailed();
    if (outcome.reaction != null) message.finalReaction = outcome.reaction;
  }

  /// T3: a group message that starts no turn goes into the history as
  /// context, labelled with who wrote it. A file is named, never downloaded.
  Future<void> context(BotMessage message) async {
    final name =
        message.senderHandle ?? message.senderDisplayName ?? message.senderId;
    final attachment = message.attachment;
    final text = attachment == null
        ? message.text
        : [
            '[file: ${attachment.name}]',
            if (attachment.caption != null) attachment.caption!,
          ].join(' ');
    await bridge.addContext(
      conversationId: message.conversationId,
      senderLabel: message.senderIsBot == true ? '$name (bot)' : name,
      text: text,
    );
  }

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
        // Not a turn (e.g. a bot the bot-talk rules refuse), but in a group
        // that reads along it is still context (spec 2026-11-13-group-topics
        // row 19).
        if (group != null &&
            group.botTalk.botsReadAll &&
            access.botTalk.hasOwner(group)) {
          await context(message);
        }
        return;
      case BotLimitNotice():
        // Unquoted on purpose (same as hermes_bridge): a quote addresses
        // the other bot, which would count the notice as one more turn.
        await bot.send(to: groupId!, text: BridgeTexts.botLimit);
        return;
      case Answer(:final label):
        // Spec A7: actions only for an owner's own 1:1 chat; groups and
        // peer bots never run them.
        final actionsAllowed =
            groupId == null && access.ownerHandle(message.senderId) != null;
        // Accepted: 👀 before the turn (spec 2026-11-11-bot-ack-reactions).
        // Ignored messages and the bot-limit notice above get nothing.
        await message.accept();
        // Files are looked at only now, after the access rules: nothing is
        // downloaded for a sender the bot would not answer (spec M4).
        final attachment = message.attachment;
        if (attachment == null) {
          settle(
            message,
            await bridge.handle(
              conversationId: message.conversationId,
              text: message.text,
              sink: _MessageSink(message),
              senderLabel: label,
              actionsAllowed: actionsAllowed,
              groupTopic: message.groupTopic,
            ),
          );
          return;
        }
        switch (await readIncomingImage(
          incomingFileOf(attachment),
          maxBytes: imageMaxBytes,
          log: log,
        )) {
          case RefusedFile(:final reply):
            await message.reply(reply);
          case AcceptedImage(:final image):
            settle(
              message,
              await bridge.handle(
                conversationId: message.conversationId,
                // The caption, never the media fallback body ("Image (12
                // KB). Update Jay..."), which is for old clients.
                text: attachment.caption ?? '',
                sink: _MessageSink(message),
                senderLabel: label,
                images: [image],
                actionsAllowed: actionsAllowed,
                groupTopic: message.groupTopic,
              ),
            );
        }
    }
  }

  // Reactions: no handler is set, so the runtime acknowledges and ignores
  // them (spec B2). Also other bots' reactions to this bot's
  // acknowledgements: they never start a turn, so two bots cannot loop.
  // Before onMessage, which connects (queued messages arrive at once).
  bot.onContext(context);
  await bot.onMessage(
    handle,
    // The group rule of A4/A5: a group with an owner in it is one this bot
    // works for, so it reads its topic and (with botsReadAll) its context
    // from every member, also from senders it does not answer.
    servesGroup: (groupId) async =>
        access.botTalk.hasOwner(await bot.group(groupId)),
    // The app sends small photos inline (`type: file`), spec M4.
    receiveFiles: true,
    allowSender: access.allowSender,
    // WHY a group lookup before decryption: only for senders that are not
    // owners, cached per group and dropped on the server's group hints.
    allowGroupSender: (id, groupId) async =>
        access.admitGroupSender(await bot.group(groupId), id),
    // Manual: [LlmAccess] decides above, and only an answered message
    // gets 👀 then ✅ / 👍 / ❌ or the model's [react:EMOJI].
    ackReactions: ackReactions ? const AckReactions(manual: true) : null,
  );
}
