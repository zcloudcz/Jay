import 'package:calltype_core/network/user_safety_api.dart';
import 'package:calltype_core/storage/database.dart';
import 'package:calltype_core/media/media_info.dart';
import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../chat/message_bubble.dart' show MessageAction;
import 'block_controller.dart';
import 'user_safety_actions.dart';

// Chat-screen side of block and report (spec 2026-11-14-go-live A7-A9). Kept
// out of chat_screen.dart, which only calls these hooks, so parallel
// branches touching that hot file merge trivially.

/// How many received messages a report from a menu offers to attach (A9).
const reportEvidenceFromMenu = 10;

/// The report text of [message]: the body of a text message, the caption
/// of a media message; null for anything else (polls, files, control rows).
String? reportTextOf(Message message) {
  if (message.deleted) return null;
  switch (message.type) {
    case 'text':
      final body = message.body?.trim() ?? '';
      return body.isEmpty ? null : body;
    case 'media':
      final caption = MediaInfo.tryDecode(message.body)?.caption?.trim();
      return caption == null || caption.isEmpty ? null : caption;
    default:
      return null;
  }
}

ReportEvidence? evidenceOf(Message message) {
  final text = reportTextOf(message);
  return text == null
      ? null
      : ReportEvidence(
          text: text,
          messageId: message.id,
          sentAt: message.createdAt,
        );
}

/// The last [limit] reportable messages [senderId] sent in [conversationId],
/// oldest first (the order the operator reads them in).
Future<List<ReportEvidence>> recentEvidence(
  AppDatabase db, {
  required String conversationId,
  required String senderId,
  int limit = reportEvidenceFromMenu,
}) async {
  final rows =
      await (db.select(db.messages)
            ..where(
              (m) =>
                  m.conversationId.equals(conversationId) &
                  m.senderId.equals(senderId) &
                  m.type.isIn(const ['text', 'media']),
            )
            ..orderBy([(m) => OrderingTerm.desc(m.createdAt)])
            ..limit(limit * 2))
          .get();
  return [
    for (final message in rows) ?evidenceOf(message),
  ].take(limit).toList().reversed.toList();
}

/// Report [personId] (a 1:1 peer or a group member) from a menu: offers to
/// attach their last received messages in this conversation.
Future<void> reportPersonFromMenu(
  BuildContext context, {
  required String personId,
  required String name,
  required String conversationId,
  String? groupId,
}) async {
  final db = context.read<AppDatabase>();
  final evidence = await recentEvidence(
    db,
    conversationId: conversationId,
    senderId: personId,
  );
  if (!context.mounted) return;
  await showReportUserDialog(
    context,
    deviceId: personId,
    name: name,
    groupId: groupId,
    evidence: evidence,
  );
}

/// "Report" and "Block" / "Unblock" for a RECEIVED message (A7). Empty when
/// the app runs without a [BlockController] (older widget tests).
List<MessageAction> messageSafetyActions(
  BuildContext context, {
  required Message message,
  required String senderName,
  required bool group,
}) {
  final blocks = context.read<BlockController?>();
  if (blocks == null) return const [];
  final l10n = context.l10n;
  final sender = message.senderId;
  final evidence = evidenceOf(message);
  return [
    MessageAction(
      icon: Icons.flag_outlined,
      label: l10n.userReport,
      onSelected: () => showReportUserDialog(
        context,
        deviceId: sender,
        name: senderName,
        groupId: group ? message.conversationId : null,
        evidence: [?evidence],
        attachByDefault: true,
      ),
    ),
    blocks.isBlocked(sender)
        ? MessageAction(
            icon: Icons.block_rounded,
            label: l10n.userUnblock,
            onSelected: () =>
                unblockUser(context, id: sender, name: senderName),
          )
        : MessageAction(
            icon: Icons.block_rounded,
            label: l10n.userBlock,
            destructive: true,
            onSelected: () =>
                confirmAndBlockUser(context, id: sender, name: senderName),
          ),
  ];
}

/// "Block" / "Unblock" and "Report" entries of the 1:1 chat menu (A7).
List<PopupMenuEntry<void>> directChatSafetyItems(
  BuildContext context, {
  required String peerId,
  required String name,
}) {
  final blocks = context.read<BlockController?>();
  if (blocks == null) return const [];
  final l10n = context.l10n;
  final blocked = blocks.isBlocked(peerId);
  return [
    PopupMenuItem(
      key: const ValueKey('chat-report-user'),
      onTap: () => reportPersonFromMenu(
        context,
        personId: peerId,
        name: name,
        conversationId: peerId,
      ),
      child: Text(l10n.userReport),
    ),
    PopupMenuItem(
      key: ValueKey(blocked ? 'chat-unblock-user' : 'chat-block-user'),
      onTap: () => blocked
          ? unblockUser(context, id: peerId, name: name)
          : confirmAndBlockUser(context, id: peerId, name: name),
      child: Text(blocked ? l10n.userUnblock : l10n.userBlock),
    ),
  ];
}

/// Shown on top of a blocked person's open 1:1 chat (A8).
class BlockedChatBanner extends StatelessWidget {
  const BlockedChatBanner({
    super.key,
    required this.peerId,
    required this.name,
  });

  final String peerId;
  final String name;

  @override
  Widget build(BuildContext context) {
    final blocks = context.watch<BlockController?>();
    if (blocks == null || !blocks.isBlocked(peerId)) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    return Container(
      key: const ValueKey('blocked-chat-banner'),
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          Icon(Icons.block_rounded, color: scheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              l10n.userBlockedBanner,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
          TextButton(
            onPressed: () => unblockUser(context, id: peerId, name: name),
            child: Text(l10n.userUnblock),
          ),
        ],
      ),
    );
  }
}
