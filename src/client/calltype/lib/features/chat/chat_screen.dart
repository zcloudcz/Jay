import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import '../../core/network/webrtc_manager.dart';
import '../../core/network/signalr_client.dart';
import '../contacts/contacts_controller.dart';
import '../chat_list/chat_list_controller.dart';
import 'chat_controller.dart';
import 'inbound/content_handler.dart' show renderableContentTypes;
import 'message_bubble.dart';
import 'message_input.dart';
import 'attachment.dart';
import '../../core/storage/database.dart';
import '../../l10n/l10n.dart';
import '../../shared/widgets/bot_badge.dart';
import '../organization/business_banner.dart';

/// One-time notice shown the first time a chat with a bot is opened: the
/// conversation is end-to-end encrypted, but the other end is an automated
/// program run by a third party who can read everything sent to it.
///
/// "Seen" is remembered per contact in the local key-value table so the
/// notice returns for every NEW bot but never nags twice about the same one.
class _BotNotice extends StatefulWidget {
  const _BotNotice({required this.contactId});
  final String contactId;

  @override
  State<_BotNotice> createState() => _BotNoticeState();
}

class _BotNoticeState extends State<_BotNotice> {
  bool _visible = false;
  String get _key => 'bot_notice_seen:${widget.contactId}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = context.read<AppDatabase>();
    final seen = await (db.select(
      db.backupState,
    )..where((s) => s.key.equals(_key))).getSingleOrNull();
    if (mounted && seen == null) setState(() => _visible = true);
  }

  Future<void> _dismiss() async {
    setState(() => _visible = false);
    final db = context.read<AppDatabase>();
    await db
        .into(db.backupState)
        .insertOnConflictUpdate(
          BackupStateCompanion.insert(key: _key, value: '1'),
        );
  }

  @override
  Widget build(BuildContext context) => !_visible
      ? const SizedBox.shrink()
      : MaterialBanner(
          leading: const Icon(Icons.smart_toy_outlined),
          content: Text(context.l10n.botNotice),
          actions: [
            TextButton(onPressed: _dismiss, child: Text(context.l10n.chatBotNoticeDismiss)),
          ],
        );
}

/// Compact "Audio call · 3 min · completed" style line for a `call-event`
/// group message (H2/H1). Never shown as an ordinary bubble — a malformed or
/// unparseable body (should not happen, the archiver validates as strictly)
/// still renders SOMETHING rather than crash the whole message list.
class _CallEventLine extends StatelessWidget {
  const _CallEventLine({required this.body});
  final String body;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    Map<String, dynamic>? data;
    try {
      data = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      data = null;
    }
    final media = data?['media'] == 'video'
        ? l10n.callEventMediaVideo
        : l10n.callEventMediaAudio;
    final outcome = switch (data?['outcome']) {
      'completed' => l10n.callOutcomeCompleted,
      'missed' => l10n.callOutcomeMissed,
      'rejected' => l10n.callOutcomeRejected,
      'failed' => l10n.callOutcomeFailed,
      'unavailable' => l10n.callOutcomeUnavailable,
      _ => l10n.callOutcomeFailed,
    };
    final startedAt = DateTime.tryParse('${data?['startedAt']}');
    final endedAt = DateTime.tryParse('${data?['endedAt']}');
    final minutes = startedAt != null && endedAt != null
        ? endedAt.difference(startedAt).inMinutes
        : null;
    final line = minutes != null && data?['outcome'] == 'completed'
        ? l10n.callEventLine(media, l10n.callEventMinutes(minutes), outcome)
        : '$media · $outcome';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Center(
        child: Text(
          line,
          style: Theme.of(context).textTheme.labelSmall,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class ChatScreen extends StatelessWidget {
  const ChatScreen({super.key, required this.contactId});
  final String contactId;
  Future<void> _call(
    BuildContext context,
    bool video, {
    String? targetDeviceId,
    String? businessGroupId,
  }) async {
    final manager = context.read<WebRTCManager>();
    try {
      await manager.startCall(
        targetDeviceId ?? contactId,
        video: video,
        businessGroupId: businessGroupId,
      );
    } catch (_) {
      if (!context.mounted) return;
      final l10n = context.l10n;
      // A business offer the hub rejected outright never reaches the ringing
      // UI, so it needs its own message here rather than on the call screen.
      final message = switch (manager.error) {
        CallError.auditorUnavailable => l10n.hubErrorAuditorUnavailable,
        CallError.notABusinessMember => l10n.chatCallFailed,
        _ => l10n.chatCallFailed,
      };
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
  }

  Future<void> _attach(BuildContext context) async {
    final controller = context.read<ChatController>();
    // Captured before the awaits; the raw exception text is for developers
    // and is not shown — the user gets one of two localized messages.
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final file = await FilePicker.pickFile();
      if (file == null) return;
      if (await file.length() > Attachment.maxBytes) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              l10n.chatAttachmentTooLarge(Attachment.maxBytes ~/ 1024),
            ),
          ),
        );
        return;
      }
      await controller.sendAttachment(file.name, await file.readAsBytes());
    } catch (_) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.chatAttachmentFailed)),
      );
    }
  }

  Future<void> _save(BuildContext context, Attachment attachment) async {
    try {
      await FilePicker.saveFile(
        fileName: attachment.name,
        bytes: attachment.bytes,
      );
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.chatAttachmentSaveFailed)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ChatController>();
    final contacts = context.watch<ContactsController>().contacts.where(
      (c) => c.deviceId == contactId,
    );
    final conversations = context
        .watch<ChatListController>()
        .conversations
        .where((c) => c.id == contactId);
    final conversation = conversations.isEmpty ? null : conversations.first;
    final group = conversation?.type == 'group';
    final contact = contacts.isEmpty ? null : contacts.first;
    final name =
        conversation?.title ??
        contact?.displayName ??
        contact?.userHandle ??
        contactId;
    final isBot = contact?.isBot ?? false;
    final organizationName = conversation?.organizationName;
    final l10n = context.l10n;
    if (controller.consumeAuditRecipientMissing()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.hubErrorAuditRecipientMissing)),
        );
      });
    }
    if (controller.consumeAuditorUnavailable()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.hubErrorAuditorUnavailable)),
        );
      });
    }
    if (controller.consumeBusinessConversationRequired()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        // P1: a redirect, not a retry — offer to open/create the business
        // conversation with this contact instead of silently rerouting the
        // message the user already typed.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.hubErrorBusinessConversationRequired),
            action: SnackBarAction(
              label: l10n.hubErrorBusinessConversationRequiredAction,
              onPressed: () async {
                final groupId = await controller
                    .createBusinessConversationWithPeer();
                if (groupId != null && context.mounted) {
                  context.go('/chats/$groupId');
                }
              },
            ),
          ),
        );
      });
    }
    return Scaffold(
      appBar: AppBar(
        title: NameWithBotBadge(name: name, isBot: isBot),
        actions: [
          // A bot is a headless program with no WebRTC stack — a call could
          // only ever ring out, so the buttons are not offered at all.
          if (!group && !isBot) ...[
            IconButton(
              icon: const Icon(Icons.call_rounded),
              tooltip: l10n.chatVoiceCall,
              onPressed: () => _call(context, false),
            ),
            IconButton(
              icon: const Icon(Icons.videocam_rounded),
              tooltip: l10n.chatVideoCall,
              onPressed: () => _call(context, true),
            ),
          ],
          // A business "1:1" is a GROUP (the two members plus the visible
          // auditor) — offer call buttons only when there is exactly one
          // other non-auditor member; a larger group has no group calls.
          if (group && organizationName != null)
            FutureBuilder<String?>(
              future: controller.businessCallTarget(),
              builder: (context, snapshot) {
                final peer = snapshot.data;
                if (peer == null) return const SizedBox.shrink();
                return Row(children: [
                  IconButton(
                    icon: const Icon(Icons.call_rounded),
                    tooltip: l10n.chatVoiceCall,
                    onPressed: () => _call(
                      context,
                      false,
                      targetDeviceId: peer,
                      businessGroupId: contactId,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.videocam_rounded),
                    tooltip: l10n.chatVideoCall,
                    onPressed: () => _call(
                      context,
                      true,
                      targetDeviceId: peer,
                      businessGroupId: contactId,
                    ),
                  ),
                ]);
              },
            ),
        ],
      ),
      body: Column(
        children: [
          if (!context.watch<SignalRClient>().connected)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(l10n.chatOffline),
            ),
          if (isBot) _BotNotice(contactId: contactId),
          // Business mode (Jay, KB1): permanent, non-dismissable — see
          // BusinessBanner's doc for why there is no close action.
          if (organizationName != null) ...[
            BusinessBanner(organizationName: organizationName),
            AuditorMemberTile(organizationName: organizationName),
          ],
          Expanded(
            child: controller.messages.isEmpty
                ? Center(child: Text(l10n.chatEmpty))
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: controller.messages.length,
                    itemBuilder: (context, index) {
                      final message = controller.messages[index];
                      // Through the DeviceDirectory (D §4.1): with more
                      // than one own device, "mine" is not just this id.
                      final mine = controller.isMine(message);
                      if (message.type == 'call-event') {
                        return _CallEventLine(body: message.body ?? '');
                      }
                      Attachment? attachment;
                      if (message.type == 'file') {
                        try {
                          attachment = Attachment.decode(message.body ?? '');
                        } catch (_) {}
                      }
                      final file = attachment;
                      return Column(
                        crossAxisAlignment: mine
                            ? CrossAxisAlignment.end
                            : CrossAxisAlignment.start,
                        children: [
                          if (group && !mine)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child: Text(
                                message.senderId,
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                            ),
                          if (file != null)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 4,
                              ),
                              child: OutlinedButton.icon(
                                onPressed: () => _save(context, file),
                                icon: const Icon(Icons.download),
                                label: Text(
                                  l10n.chatAttachmentLabel(
                                    file.name,
                                    l10n.sizeBytes(file.bytes.length),
                                  ),
                                ),
                              ),
                            )
                          else
                            MessageBubble(
                              // A type this version cannot render (K1) is
                              // kept and shown as a placeholder — never as
                              // its raw JSON body.
                              text:
                                  renderableContentTypes.contains(message.type)
                                  ? message.body ?? ''
                                  : l10n.msgUnsupportedType,
                              time: DateFormat.Hm(l10n.localeName).format(
                                message.createdAt.toLocal(),
                              ),
                              isMine: mine,
                            ),
                          if (mine)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child:
                                  message.status == 'failed' ||
                                      message.status == 'sending'
                                  ? TextButton(
                                      onPressed: () =>
                                          controller.retryMessage(message.id),
                                      child: Text(
                                        message.status == 'failed'
                                            ? l10n.chatStatusFailedRetry
                                            : l10n.chatStatusSendingRetry,
                                      ),
                                    )
                                  : Text(
                                      l10n.chatStatusSent,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.labelSmall,
                                    ),
                            ),
                        ],
                      );
                    },
                  ),
          ),
          MessageInput(
            onSend: controller.sendMessage,
            onAttachment: () => _attach(context),
          ),
        ],
      ),
    );
  }
}
