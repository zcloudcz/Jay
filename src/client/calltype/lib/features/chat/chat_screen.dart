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
import '../../shared/widgets/bot_badge.dart';

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
          content: const Text(botNotice),
          actions: [
            TextButton(onPressed: _dismiss, child: const Text('Got it')),
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
          const SnackBar(
            content: Text(
              'Unable to start the call. Check connection and permissions.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _attach(BuildContext context) async {
    final controller = context.read<ChatController>();
    try {
      final file = await FilePicker.pickFile();
      if (file == null) return;
      if (await file.length() > Attachment.maxBytes) {
        throw const FormatException('Beta attachments support up to 256 KiB.');
      }
      await controller.sendAttachment(file.name, await file.readAsBytes());
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
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
          const SnackBar(content: Text('Unable to save attachment.')),
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
    return Scaffold(
      appBar: AppBar(
        title: NameWithBotBadge(name: name, isBot: isBot),
        actions: [
          // A bot is a headless program with no WebRTC stack — a call could
          // only ever ring out, so the buttons are not offered at all.
          if (!group && !isBot) ...[
            IconButton(
              icon: const Icon(Icons.call_rounded),
              tooltip: 'Voice call',
              onPressed: () => _call(context, false),
            ),
            IconButton(
              icon: const Icon(Icons.videocam_rounded),
              tooltip: 'Video call',
              onPressed: () => _call(context, true),
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          if (!context.watch<SignalRClient>().connected)
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text('Offline. Failed messages can be retried.'),
            ),
          if (isBot) _BotNotice(contactId: contactId),
          Expanded(
            child: controller.messages.isEmpty
                ? const Center(child: Text('No messages yet. Say hello!'))
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
                                  '${file.name} (${file.bytes.length} bytes)',
                                ),
                              ),
                            )
                          else
                            MessageBubble(
                              text: message.body ?? '',
                              time: DateFormat.Hm().format(
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
                                            ? 'Failed — retry'
                                            : 'Sending — retry',
                                      ),
                                    )
                                  : Text(
                                      'Sent',
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
