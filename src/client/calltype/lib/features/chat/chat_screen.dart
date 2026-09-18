import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import '../../core/network/webrtc_manager.dart';
import '../../core/network/signalr_client.dart';
import '../contacts/contacts_controller.dart';
import '../chat_list/chat_list_controller.dart';
import 'chat_controller.dart';
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

class ChatScreen extends StatelessWidget {
  const ChatScreen({super.key, required this.contactId});
  final String contactId;
  Future<void> _call(BuildContext context, bool video) async {
    try {
      await context.read<WebRTCManager>().startCall(contactId, video: video);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.chatCallFailed)),
        );
      }
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
                      final mine = message.senderId == controller.myDeviceId;
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
                              text: message.body ?? '',
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
