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
    return Scaffold(
      appBar: AppBar(
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (!group) ...[
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
