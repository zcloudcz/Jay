import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../contacts/contacts_controller.dart';
import 'chat_controller.dart';
import 'message_bubble.dart';
import 'message_input.dart';

/// Full-screen chat view for a single conversation.
///
/// Shows messages in a reversed ListView (newest at bottom, scroll up for
/// history) with a message input bar pinned at the bottom. The AppBar
/// displays the contact name and action buttons for voice/video calls.
///
/// All state lives in [ChatController] (provided route-scoped by the
/// router): it loads message history from the local encrypted database,
/// decrypts incoming SignalR messages, and encrypts + sends outgoing ones.
/// This widget only renders the controller's message list and forwards
/// the user's input to it.
class ChatScreen extends StatelessWidget {
  const ChatScreen({super.key, required this.contactId});

  /// The device ID of the chat partner (doubles as the conversation ID
  /// for direct chats).
  final String contactId;

  /// Resolves a human-readable title for the conversation: the contact's
  /// display name, falling back to their handle, falling back to a
  /// shortened device ID for peers not (yet) in the contact list.
  String _contactName(BuildContext context) {
    final contacts = context.watch<ContactsController>().contacts;
    for (final contact in contacts) {
      if (contact.deviceId == contactId) {
        return contact.displayName ?? contact.userHandle;
      }
    }
    // Unknown peer — show enough of the ID to be recognizable without
    // overflowing the AppBar.
    return contactId.length > 13 ? '${contactId.substring(0, 13)}…' : contactId;
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ChatController>();
    final messages = controller.messages;

    return Scaffold(
      appBar: AppBar(
        title: Text(_contactName(context)),
        actions: [
          // Voice call — will trigger WebRTC offer flow in Phase 6.
          IconButton(
            icon: const Icon(Icons.call_rounded),
            tooltip: 'Voice call',
            onPressed: () {
              // TODO: Initiate WebRTC voice call in Phase 6.
            },
          ),
          // Video call — same WebRTC flow but with video track enabled.
          IconButton(
            icon: const Icon(Icons.videocam_rounded),
            tooltip: 'Video call',
            onPressed: () {
              // TODO: Initiate WebRTC video call in Phase 6.
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Message list fills available space. Using Expanded ensures
          // the input bar stays at the bottom even with few messages.
          Expanded(
            child: messages.isEmpty
                ? const Center(
                    child: Text('No messages yet. Say hello!'),
                  )
                : ListView.builder(
                    // Reversed so new messages appear at the bottom and
                    // the list auto-scrolls to show them. The controller
                    // orders messages newest-first to match.
                    reverse: true,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final msg = messages[index];
                      return MessageBubble(
                        // body is null only for non-text messages
                        // (attachments — Phase 5); render a placeholder.
                        text: msg.body ?? '[attachment]',
                        time: DateFormat.Hm().format(msg.createdAt),
                        isMine: msg.senderId == controller.myDeviceId,
                      );
                    },
                  ),
          ),
          // Input bar pinned at bottom of the screen.
          MessageInput(onSend: controller.sendMessage),
        ],
      ),
    );
  }
}
